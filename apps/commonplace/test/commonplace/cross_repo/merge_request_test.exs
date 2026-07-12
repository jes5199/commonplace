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
end
