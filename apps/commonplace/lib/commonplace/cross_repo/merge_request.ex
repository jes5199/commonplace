defmodule Commonplace.CrossRepo.MergeRequest do
  @moduledoc """
  Cross-repo B2 — the signed merge-request PROPOSAL artifact.

  A merge-request is INERT DATA: "here is a delta I'd like applied to your
  document." The proposer's signature proves **integrity + attribution** — this
  delta really came from the holder of the proposer's key, untampered — and
  grants **NO authority** to write the target. It is a self-contained,
  self-verifying value in exactly the sense a capability/cert is: judged by its
  own carried signature against an expected public key, never by the transport
  that carried it.

  Verifying a proposal answers ONE question: "did this really come from B,
  unmodified?" Whether the embodied delta MAY be applied to A's document is a
  separate, orthogonal judgment made later by A's own write-gate when A
  re-authors the delta as A's own commit (spec §0, §5). This module contains
  none of that apply/authority logic — it is pure value + crypto.

  ## Signed fields

    * `:target_uuid` — the A-doc the proposal proposes to edit.
    * `:base_cid` — A's HEAD the delta was authored against (recorded for A's
      review; staleness is A's concern at apply time).
    * `:delta` — a Yjs update, opaque bytes.
    * `:proposer_id` — the proposer's identity uuid.
    * `:message` — human note.

  `:sig` (the Ed25519 signature over the canonical encoding of the signed
  fields) is NOT itself a signed field.
  """

  alias Commonplace.Crypto.SigningContext

  @enforce_keys [:target_uuid, :base_cid, :delta, :proposer_id, :message]
  defstruct [:target_uuid, :base_cid, :delta, :proposer_id, :message, :sig]

  @type t :: %__MODULE__{
          target_uuid: String.t(),
          base_cid: String.t(),
          delta: binary(),
          proposer_id: String.t(),
          message: String.t(),
          sig: binary() | nil
        }

  # Domain-separation tag: binds these bytes to "a B2 merge-request v1" so a
  # signature can never be mistaken for a signature over some other artifact.
  @domain "commonplace.cross_repo.merge_request.v1"

  @doc """
  Deterministic, unambiguous byte encoding of the SIGNED fields (everything
  EXCEPT `:sig`).

  Same field values → identical bytes, always. Built explicitly from the fields
  as a length-prefixed concatenation (32-bit big-endian length + bytes per
  field, in a fixed order, behind a domain tag) so there is no map-ordering
  nondeterminism and no boundary ambiguity between adjacent fields.
  """
  @spec canonical_bytes(t()) :: binary()
  def canonical_bytes(%__MODULE__{} = mr) do
    [
      @domain,
      mr.target_uuid,
      mr.base_cid,
      mr.delta,
      mr.proposer_id,
      mr.message
    ]
    |> Enum.map(&encode_field/1)
    |> IO.iodata_to_binary()
  end

  defp encode_field(field) when is_binary(field) do
    [<<byte_size(field)::unsigned-big-integer-size(32)>>, field]
  end

  @doc """
  Sign the unsigned fields with the proposer's Ed25519 private key.

  `fields` is a map (or keyword) carrying `:target_uuid`, `:base_cid`, `:delta`,
  `:message` — `:proposer_id` is taken from the signing context's
  `:identity_uuid` (the proposer's carried identity, so it cannot disagree with
  who actually signed). Returns a `%MergeRequest{}` with `:sig` set.
  """
  @spec sign(map() | keyword(), SigningContext.t()) :: t()
  def sign(fields, %SigningContext{} = ctx) do
    fields = Map.new(fields)

    mr = %__MODULE__{
      target_uuid: Map.fetch!(fields, :target_uuid),
      base_cid: Map.fetch!(fields, :base_cid),
      delta: Map.fetch!(fields, :delta),
      proposer_id: ctx.identity_uuid,
      message: Map.fetch!(fields, :message)
    }

    sig = :crypto.sign(:eddsa, :none, canonical_bytes(mr), [ctx.private_key, :ed25519])
    %{mr | sig: sig}
  end

  @doc """
  Verify the proposal's signature against an EXPECTED raw Ed25519 public key.

  Returns `:ok` iff `:sig` is a valid Ed25519 signature over `canonical_bytes/1`
  by `expected_pubkey`, else `{:error, reason}`. This is attribution/integrity
  ONLY — it grants no authority over the target document.
  """
  @spec verify(t(), binary()) :: :ok | {:error, atom()}
  def verify(%__MODULE__{sig: nil}, _expected_pubkey), do: {:error, :unsigned}

  def verify(%__MODULE__{sig: sig} = mr, expected_pubkey)
      when is_binary(sig) and is_binary(expected_pubkey) do
    case :crypto.verify(:eddsa, :none, canonical_bytes(mr), sig, [expected_pubkey, :ed25519]) do
      true -> :ok
      false -> {:error, :bad_signature}
    end
  end
end
