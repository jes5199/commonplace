defmodule Commonplace.Federation.PeerTrust do
  @moduledoc """
  Cross-repo Slice-0 (2026-07-11 trust-seam spec, §1 Seam B / LBD-1) — B
  PINS A's root trust-key by folding each identity-bound federation peer's
  `root_pubkey` into B's `Trust.config/0` `trusted_identities` anchor set.

  This is deliberately almost-no-new-code: `Trust.VerifyChain.verify_chain`
  + `anchor_keys` + `verify_against_pinned` are UNCHANGED (spec §1 Seam B,
  §4 self-contained-cross-root-verifier) — cross-repo verification just
  means a peer's root ends up as one more entry in the SAME
  `trusted_identities` map every local commit is already checked against.
  A peer without a `root_pubkey` (bearer-token-only, not identity-bound)
  contributes nothing here — see `CrossRepoRef.resolve/1`'s matching
  refusal.

  Peers are keyed by `name` in `trusted_identities` (`"peer:<name>"`, to
  avoid colliding with local identity_uuids) — the ANCHOR KEY doesn't need
  to equal A's own internal identity_uuid; what matters is that A's
  signature verifies against the pinned pubkey (`verify_against_pinned`
  compares raw key bytes, not the map key).
  """

  @doc """
  Merge every identity-bound peer's `root_pubkey` into `cfg.trusted_identities`
  (base64-encoded, same shape `Trust.config/0` already expects). Peers
  without a `root_pubkey` are skipped (not identity-bound — see
  `CrossRepoRef.resolve/1`).
  """
  @spec merge_peer_anchors(Commonplace.Trust.config(), [map()]) :: Commonplace.Trust.config()
  def merge_peer_anchors(cfg, peers) when is_map(cfg) and is_list(peers) do
    additions =
      peers
      |> Enum.filter(&is_binary(Map.get(&1, :root_pubkey)))
      |> Map.new(fn peer -> {anchor_key(peer), Map.fetch!(peer, :root_pubkey)} end)

    %{cfg | trusted_identities: Map.merge(cfg.trusted_identities, additions)}
  end

  @doc """
  Convenience: fold the `:commonplace, :federation_pull` peers (if any)
  into `base_cfg` (default `Commonplace.Trust.config/0`).
  """
  @spec with_configured_peer_anchors(Commonplace.Trust.config() | nil) ::
          Commonplace.Trust.config()
  def with_configured_peer_anchors(base_cfg \\ nil) do
    cfg = base_cfg || Commonplace.Trust.config()

    peers =
      case Application.get_env(:commonplace, :federation_pull) do
        %{peers: peers} -> peers
        _ -> []
      end

    merge_peer_anchors(cfg, peers)
  end

  defp anchor_key(%{name: name}) when is_binary(name), do: "peer:" <> name
end
