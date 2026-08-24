defmodule Commonplace.Import.MonolithReaderTest do
  @moduledoc """
  The source-side import reader (`commonplace-doc-sync` v0.2 §5a.4).

  The arms that earn their cost are the ones where a defect would be
  SILENT rather than loud:

    * the reader does not MUTATE the source (a read that mints a lazy
      snapshot would break doc-sync's "the source is not mutated by
      fork" invariant — and would do it from the one operation nobody
      guards);
    * `document_id` comes from the `{:doc_commit}` OWNERSHIP key, so a
      fork-lineage document is enumerated under its own identity rather
      than its ancestor's (the 116-doc trap);
    * decode is STRICT — a concatenated body is refused, never
      truncated;
    * granularity: a flat document must NOT acquire spurious tags. ⭐ A
      walk that tags everything preserves nesting perfectly and is
      exactly as wrong as one that tags nothing, so this arm is the one
      that makes the tagging claim mean anything.

  ⚠️ NOT COVERED HERE, stated rather than implied: the NESTED arm. Nested
  Y-types are decodable but not creatable through this stack's API —
  `{:type, ref}` appears only in yelixer's encoder, so nested values
  enter a monolith store only from updates authored elsewhere (a browser
  Yjs client, a federated peer). Building one demands hand-crafting
  yelixer-internal structures, and a fixture I hand-build to match my own
  walk would test that the walk agrees with my model of the format, not
  with the format. ⇒ **The nested branch of `tagged_value/2` is
  UNDEMONSTRATED.** It is written to the shape yelixer's own
  `sub_type_to_json/2` dispatches on, and it REFUSES (never silently
  flattens) on a kind it does not recognise — but until a real
  nested-bearing update is available as a fixture, that branch carries no
  green arm and this file says so rather than implying coverage.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Import.MonolithReader
  alias Commonplace.Store.CommitStore
  alias Yelixer.Encoding

  setup do
    parent = Path.join(System.tmp_dir!(), "mono_reader_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(parent, "commits"))
    name = :"seed_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: parent, name: name})
    on_exit(fn -> File.rm_rf!(parent) end)
    %{parent: parent, seed: name}
  end

  defp text_doc(name, content) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, name)
    |> ContentType.insert_text(0, content)
  end

  defp commit_text(store, uuid, name, content) do
    CommitStore.create_commit(store, uuid, Encoding.encode_update(text_doc(name, content)), nil)
  end

  # Reopen through the adapter. The seed store holds the single-opener
  # flock, so it must be STOPPED first — via stop_supervised! rather than
  # GenServer.stop, so ExUnit's supervisor releases it synchronously
  # instead of racing the adapter's open.
  defp with_reader(parent, _seed, fun) do
    :ok = stop_supervised!(CommitStore)
    {:ok, h} = MonolithReader.open(parent)

    try do
      fun.(h)
    after
      MonolithReader.close(h)
    end
  end

  describe "open/1 — the traps that cost real runs" do
    test "refuses a path with no store rather than creating one", %{parent: parent} do
      assert {:error, {:no_store, _}} = MonolithReader.open(Path.join(parent, "nope"))
    end

    test "refuses a VACUOUS store — the wrong-path-creates-an-empty-store trap", %{parent: parent} do
      empty = Path.join(parent, "empty")
      File.mkdir_p!(Path.join(empty, "commits"))
      assert {:error, {:vacuous, _, _}} = MonolithReader.open(empty)
    end
  end

  describe "read_at/3" do
    test "materializes text at a pin, with both foreign ids as provenance",
         %{parent: parent, seed: seed} do
      c = commit_text(seed, "u-a", "a.txt", "hello")

      with_reader(parent, seed, fn h ->
        assert {:ok, out} = MonolithReader.read_at(h, "u-a", c.id)
        assert out.content_type == :text
        assert out.content == "hello"
        assert out.provenance == %{document_id: "u-a", content_head: c.id}
      end)
    end

    test "a pin reads THE PINNED STATE, not the current head", %{parent: parent, seed: seed} do
      c1 = commit_text(seed, "u-a", "a.txt", "one")
      {:ok, d1} = Commonplace.Tree.DocBuilder.reconstruct_doc(seed, "u-a", mint: false)
      d2 = ContentType.insert_text(d1, 3, " two")
      c2 = CommitStore.create_chained_commit(seed, "u-a", Encoding.encode_update(d2))

      with_reader(parent, seed, fn h ->
        assert {:ok, %{content: "one"}} = MonolithReader.read_at(h, "u-a", c1.id)
        assert {:ok, %{content: "one two"}} = MonolithReader.read_at(h, "u-a", c2.id)
      end)
    end

    test "a pin not on the document's chain is a NAMED refusal", %{parent: parent, seed: seed} do
      _a = commit_text(seed, "u-a", "a.txt", "hello")
      foreign = commit_text(seed, "u-other", "o.txt", "elsewhere")

      with_reader(parent, seed, fn h ->
        assert {:error, {:not_on_chain, _}} = MonolithReader.read_at(h, "u-a", foreign.id)
      end)
    end

    test "empty replay is a VALID import, never an error", %{parent: parent, seed: seed} do
      {:ok, genesis} = CommitStore.ensure_genesis(seed, "u-empty")

      with_reader(parent, seed, fn h ->
        # A genesis pin replays nothing and IS the empty state. Not found
        # would be wrong: doc-sync's selected_head must stay non-nullable.
        assert {:error, {:unrenderable_content_type, _}} =
                 MonolithReader.read_at(h, "u-empty", genesis.id)
      end)
    end
  end

  describe "strict decode — the truncation this reader refuses to perform" do
    test "a concatenated update body is REFUSED, not silently truncated",
         %{parent: parent, seed: seed} do
      d1 = text_doc("c.txt", "alpha")
      u1 = Encoding.encode_update(d1)
      u2 = d1 |> ContentType.insert_text(5, "beta") |> Encoding.encode_update()

      # Planted directly, because no writer in the tree produces this —
      # which is exactly why nothing downstream would notice it.
      c = CommitStore.create_commit(seed, "u-cat", u1 <> u2, nil)

      with_reader(parent, seed, fn h ->
        assert {:error, {:trailing_bytes, n}} = MonolithReader.read_at(h, "u-cat", c.id)
        assert n > 0
      end)
    end

    test "GREEN ARM: a single well-formed update is accepted", %{parent: parent, seed: seed} do
      # Without this, a validator that rejected EVERYTHING would pass the
      # arm above and be indistinguishable from a working one.
      c = commit_text(seed, "u-ok", "ok.txt", "fine")

      with_reader(parent, seed, fn h ->
        assert {:ok, %{content: "fine"}} = MonolithReader.read_at(h, "u-ok", c.id)
      end)
    end
  end

  describe "granularity — the arm that makes the tagging claim mean anything" do
    test "a FLAT map does not acquire spurious nesting tags", %{parent: parent, seed: seed} do
      doc =
        Yelixer.Doc.new()
        |> ContentType.create(:map, "m.json")
        |> ContentType.set_key("plain", "v")
        |> ContentType.set_key("num", 1)

      c = CommitStore.create_commit(seed, "u-m", Encoding.encode_update(doc), nil)

      with_reader(parent, seed, fn h ->
        assert {:ok, %{content_type: :map, content: json}} =
                 MonolithReader.read_at(h, "u-m", c.id)

        decoded = Jason.decode!(json)

        # Every slot is tagged as a plain VALUE — none as a nested type.
        assert decoded["plain"] == %{"t" => "value", "v" => "v"}
        assert decoded["num"] == %{"t" => "value", "v" => 1}
        refute Enum.any?(decoded, fn {_k, v} -> v["t"] in ["ymap", "yarray", "ytext"] end)
      end)
    end
  end

  describe "list_documents/1 — enumeration keyed on OWNERSHIP" do
    test "enumerates from {:doc_commit} and reconciles against {:latest}",
         %{parent: parent, seed: seed} do
      commit_text(seed, "u-a", "a.txt", "one")
      commit_text(seed, "u-b", "b.txt", "two")

      with_reader(parent, seed, fn h ->
        assert {:ok, docs, report} = MonolithReader.list_documents(h)
        ids = Enum.map(docs, & &1.document_id)
        assert "u-a" in ids and "u-b" in ids
        assert report.total == length(docs)
        # On a store built through the API the two populations agree —
        # reported, never assumed.
        assert report.headed_not_owned == []
      end)
    end

    test "a fork-lineage document is enumerated under ITS OWN id, not its ancestor's",
         %{parent: parent, seed: seed} do
      # The 116-doc trap in miniature: a head POINTER copied to a new doc
      # while the ownership rows stayed with the ancestor. A reader keyed
      # on commit.doc_uuid would report the ancestor's identity here.
      c = commit_text(seed, "u-anc", "a.txt", "one")
      CubDB.put(CommitStore.db_handle(seed), {:latest, "u-fork"}, c.id)

      with_reader(parent, seed, fn h ->
        assert {:ok, docs, report} = MonolithReader.list_documents(h)
        ids = Enum.map(docs, & &1.document_id)

        assert "u-fork" in ids, "the forked doc must appear under its own id"
        # And the gap is REPORTED rather than silently absorbed.
        assert "u-fork" in report.headed_not_owned
      end)
    end
  end

  describe "the source is not mutated by a read" do
    test "reading does not add commits to the source store", %{parent: parent, seed: seed} do
      c = commit_text(seed, "u-a", "a.txt", "hello")

      with_reader(parent, seed, fn h ->
        db = CommitStore.db_handle(h.store)
        before = CubDB.select(db) |> Enum.count()

        assert {:ok, _} = MonolithReader.read_at(h, "u-a", c.id)
        assert {:ok, _} = MonolithReader.read_at(h, "u-a", c.id)

        assert CubDB.select(db) |> Enum.count() == before,
               "a read minted rows into the source store — the reader is a writer"
      end)
    end
  end
end
