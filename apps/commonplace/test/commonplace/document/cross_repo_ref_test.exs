defmodule Commonplace.Document.CrossRepoRefTest do
  @moduledoc """
  Cross-repo Slice-0 (2026-07-11 spec, §1 Seam D / §3.1): the `peer:uuid`
  reference + peer↔repo-identity resolver. Small and mechanical — parse
  a string, resolve a peer LABEL to its identity-bound config (the
  `root_pubkey` is what makes "A" a verifiable repo identity, not a
  mutable URL).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.CrossRepoRef

  setup do
    on_exit(fn -> Application.delete_env(:commonplace, :federation_pull) end)
  end

  describe "parse/1" do
    test "splits peer:uuid" do
      assert {:ok, %CrossRepoRef{peer: "repo-a", uuid: "550e8400-e29b-41d4-a716-446655440000"}} =
               CrossRepoRef.parse("repo-a:550e8400-e29b-41d4-a716-446655440000")
    end

    test "rejects a string with no separator" do
      assert {:error, :invalid_format} = CrossRepoRef.parse("no-colon-here")
    end

    test "rejects an empty peer or uuid side" do
      assert {:error, :invalid_format} = CrossRepoRef.parse(":uuid")
      assert {:error, :invalid_format} = CrossRepoRef.parse("peer:")
    end
  end

  describe "to_string/1 round-trips" do
    test "formats back to peer:uuid" do
      ref = %CrossRepoRef{peer: "repo-a", uuid: "u1"}
      assert CrossRepoRef.to_string(ref) == "repo-a:u1"
      assert "#{ref}" == "repo-a:u1"
    end
  end

  describe "resolve/1" do
    test "resolves the peer label to its identity-bound config" do
      Application.put_env(:commonplace, :federation_pull, %{
        peers: [
          %{
            name: "repo-a",
            base_url: "https://a.example",
            token: "s3cret",
            root_pubkey: "pinned-key",
            docs: []
          }
        ]
      })

      assert {:ok, ref} = CrossRepoRef.parse("repo-a:doc-1")
      assert {:ok, peer} = CrossRepoRef.resolve(ref)
      assert peer.root_pubkey == "pinned-key"
      assert peer.base_url == "https://a.example"
    end

    test "unknown peer label is refused" do
      Application.put_env(:commonplace, :federation_pull, %{peers: []})
      {:ok, ref} = CrossRepoRef.parse("nope:doc-1")
      assert {:error, :unknown_peer} = CrossRepoRef.resolve(ref)
    end

    test "a peer configured WITHOUT a root_pubkey is not identity-bound — refused" do
      Application.put_env(:commonplace, :federation_pull, %{
        peers: [%{name: "repo-a", base_url: "https://a.example", token: "s3cret", docs: []}]
      })

      {:ok, ref} = CrossRepoRef.parse("repo-a:doc-1")
      assert {:error, :peer_not_identity_bound} = CrossRepoRef.resolve(ref)
    end
  end
end
