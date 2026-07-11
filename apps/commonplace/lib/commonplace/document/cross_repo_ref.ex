defmodule Commonplace.Document.CrossRepoRef do
  @moduledoc """
  Cross-repo Slice-0 (2026-07-11 trust-seam spec, §1 Seam D) — a reference to
  a document living in a FOREIGN repo, addressed by (repo-identity, uuid).

  Format: `peer:uuid` — e.g. `repo-a:550e8400-e29b-41d4-a716-446655440000`.
  `peer` is the federation peer's NAME as configured under
  `:commonplace, :federation_pull` — a mutable local label. What actually
  makes "A" a stable, verifiable identity is NOT the name but the peer's
  pinned `root_pubkey` (see `resolve/1`): the name is who-you-call-it,
  the root_pubkey is who-they-ARE.

  This is a sibling of `Commonplace.Document.DocRef`, not a replacement —
  `DocRef` addresses docs within the LOCAL tree; `CrossRepoRef` addresses a
  doc across the federation trust-root boundary. Keep it minimal: parse +
  resolve, no new tree-node machinery (a resolved cross-repo ref is used to
  configure a `Federation.PullClient` peer/doc pull + read-replicate; the
  local tree side just holds a reference, per the design's §2).
  """

  @type t :: %__MODULE__{peer: String.t(), uuid: String.t()}

  defstruct [:peer, :uuid]

  @doc """
  Parse a `"peer:uuid"` string into a `%CrossRepoRef{}`. `{:error,
  :invalid_format}` if there's no `:` separator or either side is empty.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(str) when is_binary(str) do
    case String.split(str, ":", parts: 2) do
      [peer, uuid] when peer != "" and uuid != "" ->
        {:ok, %__MODULE__{peer: peer, uuid: uuid}}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc "Format a `%CrossRepoRef{}` back to its `\"peer:uuid\"` string form."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{peer: peer, uuid: uuid}), do: "#{peer}:#{uuid}"

  @doc """
  Resolve a ref's `peer` label to its full identity-bound endpoint config —
  `%{name:, base_url:, token:, root_pubkey:, docs:}` — by looking it up in
  the configured `:commonplace, :federation_pull` peers (by `:name`). This
  is the peer↔repo-identity binding (spec §1 Seam D / §3.2): "A" resolves
  to (A's root trust-key, A's mutable base_url/token), never just a URL.

  `{:error, :unknown_peer}` if no configured peer matches the ref's `peer`
  label. `{:error, :peer_not_identity_bound}` if the peer is configured
  without a `root_pubkey` — such a peer can be pulled from (bearer-token
  gated) but cannot be trusted as a verifiable repo identity, so a
  `CrossRepoRef` through it is refused (an `A:uuid` reference is only as
  strong as A's pinned root).
  """
  @spec resolve(t()) :: {:ok, map()} | {:error, :unknown_peer | :peer_not_identity_bound}
  def resolve(%__MODULE__{peer: peer_name}) do
    peers =
      case Application.get_env(:commonplace, :federation_pull) do
        %{peers: peers} -> peers
        _ -> []
      end

    case Enum.find(peers, &(Map.get(&1, :name) == peer_name)) do
      nil -> {:error, :unknown_peer}
      %{root_pubkey: pk} = peer when is_binary(pk) and pk != "" -> {:ok, peer}
      %{} -> {:error, :peer_not_identity_bound}
    end
  end
end

defimpl String.Chars, for: Commonplace.Document.CrossRepoRef do
  def to_string(ref), do: Commonplace.Document.CrossRepoRef.to_string(ref)
end
