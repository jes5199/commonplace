defmodule CommonplaceWebWeb.Plugs.FederationAuth do
  @moduledoc """
  Bearer-token gate for the federation endpoints (phase C, CX-orfw).

  Two-auth-layers rule (federation.md): this plug is the ONLINE layer —
  "may you talk to this endpoint at all." It is transport hygiene, not
  authorization: whether a commit LANDS is decided offline by Gate A
  (`import_commit` → `Trust.authorized?`), which this plug never touches.

  Peers are configured as `token => peer_name`:

      config :commonplace_web, :federation_peers, %{"s3cret" => "peer-a"}

  No configured peers ⇒ federation is OFF and every request 403s — the
  secure default for workspaces that never opted in.

  ## Cross-repo Slice-0 (2026-07-11 spec, §1 Seam C) — identity-bound peers

  A peer entry MAY instead be a map naming the requester's identity, so
  the `:read`-cert gate (`FederationController`) can use the
  SERVER-RESOLVED requester key for the audience-binding check — NEVER a
  client-claimed value:

      config :commonplace_web, :federation_peers,
        %{"s3cret" => %{name: "peer-b", identity_uuid: "repo-b-root", pubkey: <<...>>}}

  A bare string peer (legacy shape) is normalized to
  `%{name: peer, identity_uuid: peer, pubkey: nil}` — it authenticates
  (transport hygiene) but never satisfies a `:read` cert's audience
  binding (no pubkey to match), so it behaves exactly as before under a
  permissive (`accept_unsigned: true`) trust config, and is correctly
  refused a doc gated under a strict one.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    peers = Application.get_env(:commonplace_web, :federation_peers, %{})

    with [<<"Bearer ", token::binary>>] <- get_req_header(conn, "authorization"),
         {:ok, peer} <- lookup(peers, token) do
      assign(conn, :federation_peer, normalize(peer))
    else
      _ ->
        conn
        |> send_resp(403, "federation: not authorized")
        |> halt()
    end
  end

  # Constant-time comparison per candidate token (the peer map is small).
  defp lookup(peers, token) do
    Enum.find_value(peers, :error, fn {candidate, peer} ->
      if Plug.Crypto.secure_compare(candidate, token), do: {:ok, peer}
    end)
  end

  defp normalize(peer) when is_binary(peer), do: %{name: peer, identity_uuid: peer, pubkey: nil}

  defp normalize(%{name: name} = peer) do
    %{
      name: name,
      identity_uuid: Map.get(peer, :identity_uuid, name),
      pubkey: Map.get(peer, :pubkey)
    }
  end
end
