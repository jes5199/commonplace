defmodule Commonplace.Federation.PullClient do
  @moduledoc """
  Pull-based federation sync (phase C, CX-orfw): `NodeSync.catch_up`'s
  CID-diff shape over HTTP instead of BEAM RPC — the non-cookie
  transport that makes two workspaces genuinely separate trust domains.

  Per configured peer and doc: fetch the peer's CID set, diff against
  the local store, fetch the missing commits as envelopes (commit +
  inlined cert chain), verify + store the certs, and route each commit
  through `NodeSync.import_with_translation/3` — the SAME ingress the
  BEAM-cluster path uses, so Gate A, cross-epoch translation (now
  node-signed, CX-tdkq.26), and the pending-import retry queue all
  apply unchanged. The transport is dumb on purpose: commits and certs
  are content-addressed and self-verifying; authorization-to-land is
  entirely the import gate's.

  Out-of-order arrivals self-heal: a commit rejected this cycle because
  its parent hadn't landed yet stays in the peer's diff and is re-pulled
  next cycle (plus R11's pending queue absorbs `:awaiting_capability`
  and namespace deferrals immediately).

  ## Configuration

      config :commonplace, :federation_pull,
        interval_ms: 30_000,
        peers: [
          %{name: "peer-a", base_url: "https://a.example", token: "s3cret",
            docs: ["<doc-uuid>", ...]}
        ]

  No config ⇒ the client is not started (federation off by default).
  The `transport` option is injectable for tests; the default speaks
  HTTP via `Req` against the `commonplace_web` federation endpoints.

  ## Cross-repo Slice-0 (2026-07-11 spec, §1 Seam C / §3.4) — presenting B's `:read` cert

  A `docs` entry may be either a bare uuid string (legacy — no cert
  presented) or `%{uuid:, read_cert_cid:}`, where `read_cert_cid` is the
  base64-encoded CID of the `:read` capability A granted B for that doc
  (minted via `Trust.Read.grant/4` on A, handed to B out-of-band — the
  same way any delegated cert reaches its holder). Every pull request
  (`cids` + `commits`) presents that cert cid to A's `:read`-cert gate
  (`FederationController`), which resolves WHO is asking from the
  authenticated bearer token (never from this param) and checks the
  cert's audience against that identity — `commits/2`'s existing
  cert-inlining behavior on the CERT-GRANTING side of a delegation chain
  is untouched; this is the READ side.
  """
  use GenServer
  require Logger

  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Sync.NodeSync

  @empty_report %{imported: 0, deferred: 0, rejected: 0, errors: []}

  # --- API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run one pull cycle over `peers` synchronously. Options: `:store`
  (default global CommitStore), `:transport` (default HTTP). Returns
  `%{imported: n, deferred: n, rejected: n, errors: [{peer, doc, reason}]}`.
  """
  def pull_once(peers, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStore)
    transport = Keyword.get(opts, :transport, &http_transport/3)

    Enum.reduce(peers, @empty_report, fn peer, acc ->
      Enum.reduce(peer.docs, acc, fn doc, acc -> pull_doc(peer, doc, store, transport, acc) end)
    end)
  end

  # --- GenServer (interval-driven wrapper around pull_once/2) ---

  @impl true
  def init(opts) do
    state = %{
      peers: Keyword.fetch!(opts, :peers),
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      store: Keyword.get(opts, :store, CommitStore),
      transport: Keyword.get(opts, :transport, &http_transport/3)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:pull, state) do
    report = pull_once(state.peers, store: state.store, transport: state.transport)

    if report.imported + report.deferred + report.rejected > 0 or report.errors != [] do
      Logger.info("Federation.PullClient: #{inspect(report)}")
    end

    schedule(state)
    {:noreply, state}
  end

  defp schedule(%{interval_ms: ms}) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :pull, ms)
  end

  defp schedule(_), do: :ok

  # --- one peer × doc pull ---

  # Normalize a `docs` entry to `{uuid, read_cert_cids}` — a bare string
  # (legacy) presents no cert; `%{uuid:, read_cert_cid:}` decodes its
  # single cid into the list `read_authorized?`-style callers expect.
  defp normalize_doc(uuid) when is_binary(uuid), do: {uuid, []}

  defp normalize_doc(%{uuid: uuid} = entry) do
    {uuid, entry |> Map.get(:read_cert_cid) |> List.wrap()}
  end

  defp pull_doc(peer, doc_entry, store, transport, acc) do
    {uuid, cert_cids} = normalize_doc(doc_entry)

    with {:ok, %{"cids" => remote_b64}} <-
           transport.(:cids, peer, %{uuid: uuid, cert_cids: cert_cids}),
         missing = diff_missing(store, uuid, remote_b64),
         {:ok, %{"envelopes" => envelopes}} <-
           fetch_missing(transport, peer, %{uuid: uuid, cert_cids: cert_cids}, missing) do
      Enum.reduce(envelopes, acc, fn encoded, acc ->
        import_envelope(store, encoded, acc, peer, uuid)
      end)
    else
      {:error, reason} -> %{acc | errors: acc.errors ++ [{peer.name, uuid, reason}]}
    end
  end

  defp diff_missing(store, doc, remote_b64) do
    local =
      CommitStoreClient.commit_ids_for_doc(store, doc)
      |> Enum.map(&Base.encode64/1)
      |> MapSet.new()

    Enum.reject(remote_b64, &MapSet.member?(local, &1))
  end

  defp fetch_missing(_transport, _peer, _doc, []), do: {:ok, %{"envelopes" => []}}

  defp fetch_missing(transport, peer, doc, missing),
    do: transport.(:commits, peer, {doc, missing})

  defp import_envelope(store, encoded, acc, peer, doc) do
    with {:ok, %{commit: commit, certs: certs, revocations: revocations}} <-
           Envelope.decode(encoded),
         :ok <- Envelope.verify_certs(certs),
         :ok <- Envelope.verify_revocations(revocations) do
      Enum.each(certs, &CommitStoreClient.store_capability(store, &1))
      # CX-bepn (design §6): store sig-consistent revocations on arrival
      # WITHOUT validating revoker authority here — see
      # `Commonplace.Trust.Revocation`'s moduledoc (§7.6) for why an
      # early-arriving revocation (before its target cert's chain is
      # known) must still be stored, not dropped.
      Enum.each(revocations, &CommitStoreClient.store_revocation(store, &1))

      case NodeSync.import_with_translation(store, commit) do
        :ok ->
          %{acc | imported: acc.imported + 1}

        {:error, {:trust_rejected, :awaiting_capability}} ->
          %{acc | deferred: acc.deferred + 1}

        {:error, _reason} ->
          %{acc | rejected: acc.rejected + 1}
      end
    else
      {:error, reason} -> %{acc | errors: acc.errors ++ [{peer.name, doc, reason}]}
    end
  end

  # --- default HTTP transport (the commonplace_web federation routes) ---

  defp http_transport(:cids, peer, %{uuid: uuid, cert_cids: cert_cids}) do
    request(:get, peer, "/federation/docs/#{uuid}/cids", nil, cert_cids_query(cert_cids))
  end

  defp http_transport(:commits, peer, {%{uuid: uuid, cert_cids: cert_cids}, cids}) do
    request(:post, peer, "/federation/docs/#{uuid}/commits", %{
      cids: cids,
      cert_cids: encode_cert_cids(cert_cids)
    })
  end

  defp cert_cids_query([]), do: []
  defp cert_cids_query(cert_cids), do: [cert_cids: Enum.join(encode_cert_cids(cert_cids), ",")]

  defp encode_cert_cids(cert_cids), do: Enum.map(cert_cids, &Base.encode64/1)

  defp request(method, peer, path, body, query \\ []) do
    opts = [
      method: method,
      url: peer.base_url <> path,
      headers: [{"authorization", "Bearer " <> peer.token}],
      params: query,
      retry: false
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %Req.Response{status: 200, body: %{} = decoded}} -> {:ok, decoded}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end
