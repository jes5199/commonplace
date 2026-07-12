defmodule Commonplace.CrossRepo.MergeRequestTest do
  use ExUnit.Case, async: true

  alias Commonplace.CrossRepo.MergeRequest
  alias Commonplace.Crypto.{Signing, SigningContext}

  # Build a proposer SigningContext the same way the rest of the test suite does:
  # a freshly-minted Ed25519 keypair (raw bytes) plugged straight in.
  defp proposer_ctx(identity \\ "proposer-B") do
    {pub, priv} = Signing.generate_keypair()
    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}
    {ctx, pub}
  end

  defp fields do
    %{
      target_uuid: "doc-X-uuid",
      base_cid: "cidbaseHEAD",
      delta: <<1, 2, 3, 0, 255, 42>>,
      message: "please apply my edit"
    }
  end

  test "a signed proposal verifies against the signer's public key" do
    {ctx, pub} = proposer_ctx()
    mr = MergeRequest.sign(fields(), ctx)

    assert mr.proposer_id == "proposer-B"
    assert is_binary(mr.sig)
    assert :ok == MergeRequest.verify(mr, pub)
  end

  test "tampering with any signed field makes verify fail" do
    {ctx, pub} = proposer_ctx()
    mr = MergeRequest.sign(fields(), ctx)

    for {field, tampered} <- [
          target_uuid: "doc-Y-uuid",
          base_cid: "cidOTHER",
          delta: <<9, 9, 9>>,
          proposer_id: "impostor",
          message: "hijacked note"
        ] do
      bad = Map.put(mr, field, tampered)
      assert {:error, :bad_signature} == MergeRequest.verify(bad, pub),
             "tampering with #{field} should fail verification"
    end
  end

  test "verify against a wrong/different public key fails" do
    {ctx, _pub} = proposer_ctx()
    mr = MergeRequest.sign(fields(), ctx)

    {wrong_pub, _priv} = Signing.generate_keypair()
    assert {:error, :bad_signature} == MergeRequest.verify(mr, wrong_pub)
  end

  test "an unsigned proposal is refused" do
    mr = struct!(MergeRequest, Map.put(fields(), :proposer_id, "proposer-B"))
    {_ctx, pub} = proposer_ctx()
    assert {:error, :unsigned} == MergeRequest.verify(mr, pub)
  end

  test "canonical_bytes is deterministic (same fields -> identical bytes)" do
    {ctx, _pub} = proposer_ctx()
    mr = MergeRequest.sign(fields(), ctx)

    assert MergeRequest.canonical_bytes(mr) == MergeRequest.canonical_bytes(mr)

    # Independently rebuilding a struct with the same signed field values yields
    # the same canonical bytes (sig is not part of the encoding).
    twin = struct!(MergeRequest, Map.put(fields(), :proposer_id, mr.proposer_id))
    assert MergeRequest.canonical_bytes(twin) == MergeRequest.canonical_bytes(mr)
  end

  test "canonical_bytes distinguishes field-boundary ambiguity" do
    base = struct!(MergeRequest, Map.put(fields(), :proposer_id, "p"))
    # Moving a byte across the target_uuid/base_cid boundary must change bytes.
    shifted = %{base | target_uuid: "doc-X-uui", base_cid: "d" <> "cidbaseHEAD"}
    refute MergeRequest.canonical_bytes(base) == MergeRequest.canonical_bytes(shifted)
  end

  describe "wire serialization (to_wire / from_wire)" do
    test "round-trips the full proposal and integrity survives" do
      {ctx, pub} = proposer_ctx()
      mr = MergeRequest.sign(fields(), ctx)

      wire = MergeRequest.to_wire(mr)
      assert is_binary(wire)

      assert {:ok, mr2} = MergeRequest.from_wire(wire)
      assert mr2 == mr
      # Integrity survives the wire round-trip: the reconstructed proposal
      # still verifies against the signer's key.
      assert :ok == MergeRequest.verify(mr2, pub)
    end

    test "round-trips fields with awkward bytes (empty, embedded nulls, 32-bit lengths)" do
      {ctx, pub} = proposer_ctx()

      mr =
        MergeRequest.sign(
          %{
            target_uuid: "doc-X-uuid",
            base_cid: "",
            delta: <<0, 0, 0, 4, 0, 255>>,
            message: "note with \0 embedded null and unicode ✓"
          },
          ctx
        )

      assert {:ok, mr2} = MergeRequest.from_wire(MergeRequest.to_wire(mr))
      assert mr2 == mr
      assert :ok == MergeRequest.verify(mr2, pub)
    end

    test "corrupted wire bytes return {:error, _} without raising" do
      {ctx, _pub} = proposer_ctx()
      wire = MergeRequest.to_wire(MergeRequest.sign(fields(), ctx))

      # Not valid Base64.
      assert {:error, _} = MergeRequest.from_wire("!!! not base64 !!!")
      # Valid Base64 but truncated payload (drop the tail).
      truncated = binary_part(wire, 0, div(byte_size(wire), 2))
      assert {:error, _} = MergeRequest.from_wire(truncated)
      # Valid Base64 of an unknown/absent version tag.
      assert {:error, _} = MergeRequest.from_wire(Base.encode64(<<>>))
      assert {:error, _} = MergeRequest.from_wire(Base.encode64(<<99, 1, 2, 3>>))
      # Non-binary input.
      assert {:error, _} = MergeRequest.from_wire(:not_a_binary)
    end

    test "flipping a byte inside the wire either fails to parse or fails to verify" do
      {ctx, pub} = proposer_ctx()
      wire = MergeRequest.to_wire(MergeRequest.sign(fields(), ctx))

      {:ok, raw} = Base.decode64(wire)
      # Flip a byte in the middle of the payload.
      i = div(byte_size(raw), 2)
      <<head::binary-size(i), b, tail::binary>> = raw
      corrupted = Base.encode64(<<head::binary, Bitwise.bxor(b, 0xFF), tail::binary>>)

      case MergeRequest.from_wire(corrupted) do
        {:error, _} -> :ok
        {:ok, mr2} -> assert {:error, _} = MergeRequest.verify(mr2, pub)
      end
    end
  end
end
