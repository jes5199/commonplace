defmodule Commonplace.Import.MonolithReader do
  @moduledoc """
  The SOURCE-side reader adapter for `commonplace-doc-sync`'s IMPORT: it
  materializes a monolith document's content at a pinned commit so a
  foreign stack can fork from it.

  Contract agreed with `commonplace-doc-sync` (their v0.2 §5a.4). Three
  things are REQUIRED of this reader and each of the rest is deliberately
  absent:

    * materialized content **at a pin** (not "current" — the pin is what
      makes the destination's recorded lineage cite the state it actually
      imported);
    * the foreign `document_id`;
    * the foreign content head id.

  ## ⛔ What this is NOT, by construction

  **Not an `Endpoint`.** No `summary`, `export`, `offer`, or `watch`; no
  authority context; no receipt. Import is **one-way and terminal** — a
  foreign store cannot be offered to, and no sync relationship exists.
  An operation with one participant otherwise acquires a two-party
  structure by analogy, so the absence is stated rather than implied.

  **Not the commit graph.** Import is a *derived-snapshot* basis: the
  destination materializes content into its own genesis commit. The
  monolith DAG is never traversed as history and never admitted. (This
  is what keeps the DAG→linear-log sequencer — which nothing in either
  stack owns — off the import path entirely.)

  **Not an epoch.** The destination MINTS its own. This reader neither
  carries a foreign epoch nor synthesizes one.

  **Not Yjs update bytes.** The seam carries a *rendered value* plus its
  content type. This is FORCED, not preferred: update bytes carry
  `{client_id, clock}` coordinates from the monolith's namespace, and a
  freshly minted destination epoch containing coordinates it did not
  author is incoherent (`yepochs` invariant 1 — a raw `{client_id,
  clock}` is meaningless without its Yepoch). Re-authoring them
  destination-side *is* rendering, with identity baggage dragged through
  a boundary it must not cross.

  ## ⛔ THREE TRAPS THIS ADAPTER IS BUILT NOT TO STEP IN

  Each would corrupt an import **silently** rather than fail it.

  1. **A naive reader of this store WRITES TO IT.** Reads can mint a
     lazy snapshot commit into the source. That mutates the store being
     imported from *and* changes which chain a later reconstruction
     walks. ⇒ **This module exposes no minting path at all.** Not a flag
     the caller must remember to pass — an interface with no route to it.
     (`commonplace-doc-sync` §5a's "the source is not mutated by fork"
     is an invariant a *read* would otherwise have broken.)

  2. **Ownership is the `{:doc_commit, doc_uuid, id}` KEY, never
     `commit.doc_uuid`.** That struct field is a first-writer trace,
     excluded from the content address and stale after forks — measured
     WRONG for 116 documents, 1.9% of the live corpus. A reader keyed on
     it imports one document's content under another's identity. ⇒ This
     module never reads that field.

  3. **`decode_update/1` returns `{items, ds, rest}` and every existing
     caller discards `rest`** — a concatenated body is silently
     truncated, yielding a document that looks whole with half its
     content gone. ⇒ Every decode here is strict: a non-empty remainder
     is `{:error, {:trailing_bytes, n}}`, never dropped. New code starts
     compliant; this is the cheapest place that gate will ever exist.

  ## Reproducibility of a pin

  The chain to a pin is fixed by immutable `parent_id` edges, so the
  replay applies the same commits in the same order and yields the same
  document. Rendering is the determinism-tested path (the GitBridge
  export measurement: 0 failures over 466 pairs, byte-identical across
  two fresh OS processes, with a must-fail control that fired).

  ⚠️ **One residual, named because it is real:** if another writer mints
  a snapshot INTO that chain between two runs, the walk shortens and the
  document is assembled by a different path. The rendered value is
  unchanged; encoded bytes might not be — which is one more reason the
  seam carries values. `mint: false` prevents *this reader* from causing
  it and cannot prevent another writer.

  ⚠️ **And determinism is not correctness:** a reproducibly-wrong render
  also passes. Conformance belongs downstream, asserting imported
  content matches source state — not merely that two imports agree.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.GitBridge.CanonicalJson
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{BlockStore, Doc, Encoding, ID, Item, Types}

  # The YMap/YArray type name `ContentType` stores document content under.
  @content_key "content"

  @min_store_bytes 1_000

  @type handle :: %{store: atom(), store_dir: String.t()}
  @type document_id :: String.t()
  @type commit_id :: binary()

  @type content :: %{
          content_type: :text | :map | :array,
          content: binary(),
          provenance: %{document_id: document_id(), content_head: commit_id()}
        }

  @doc """
  Open a monolith store for reading.

  `store_parent` is the **PARENT** directory — `CommitStore` appends
  `/commits`. Passing the `commits` directory itself CREATES a fresh
  empty store on open and every subsequent read "succeeds" against
  nothing, so this refuses before opening rather than after.

  ⚠️ The store is single-opener (flock): this needs a **stopped** serve's
  data dir or a copy. It cannot read a live store concurrently.
  """
  @spec open(Path.t()) ::
          {:ok, handle()}
          | {:error, {:no_store, String.t()}}
          | {:error, {:vacuous, String.t(), non_neg_integer()}}
  def open(store_parent) do
    store_dir = Path.join(store_parent, "commits")

    cond do
      not File.dir?(store_dir) ->
        {:error, {:no_store, store_dir}}

      cub_bytes(store_dir) < @min_store_bytes ->
        {:error, {:vacuous, store_dir, cub_bytes(store_dir)}}

      true ->
        name = :"monolith_reader_#{System.unique_integer([:positive])}"
        {:ok, _pid} = CommitStore.start_link(data_dir: store_parent, name: name)
        {:ok, %{store: name, store_dir: store_dir}}
    end
  end

  @doc "Release the store. Safe to call twice."
  @spec close(handle()) :: :ok
  def close(%{store: name}) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc """
  Enumerate importable documents, with the enumeration's own
  reconciliation report.

  Documents are enumerated from the `{:doc_commit}` OWNERSHIP keys — the
  authoritative doc→commit map — and reconciled against the `{:latest}`
  head pointers. The two populations coincided when last measured
  (2026-08-23: 6115 == 6115, zero orphans), but that is a **dated fact
  about a corpus, not a property of the format**, so the report names
  any gap rather than asserting the zero.

    * `owned_not_headed` — has commits, no head pointer. Not importable
      at "the head" (no pin to offer), but importable at an explicit pin.
    * `headed_not_owned` — head pointer with no ownership rows. This was
      the fork-lineage defect (116 docs) before it was backfilled; a
      non-empty list here means the source store predates that repair.

  One unbounded pass over the keyspace: a range-bounded scan risks
  dropping the high end silently, and both populations must come from
  the same traversal to be comparable at all. That pass belongs to the
  storage adapter, not here — see `CommitStore.import_population/1`. An
  earlier draft of this function reached for `CommitStore.db_handle/1`
  and `CubDB.select` directly; the read-perimeter guard
  (`scripts/check_commonplace_cubdb_reads.exs`) refused it in CI, which
  is the guard doing exactly its job on the newest caller.
  """
  @spec list_documents(handle()) ::
          {:ok, [%{document_id: document_id(), head_commit_id: commit_id() | nil}], map()}
  def list_documents(%{store: name}) do
    %{owned: owned, heads: heads} = CommitStore.import_population(name)

    headed = heads |> Map.keys() |> MapSet.new()

    docs =
      owned
      |> MapSet.union(headed)
      |> Enum.sort()
      |> Enum.map(&%{document_id: &1, head_commit_id: Map.get(heads, &1)})

    report = %{
      owned: MapSet.size(owned),
      headed: MapSet.size(headed),
      owned_not_headed: owned |> MapSet.difference(headed) |> Enum.sort(),
      headed_not_owned: headed |> MapSet.difference(owned) |> Enum.sort(),
      total: length(docs)
    }

    {:ok, docs, report}
  end

  @doc """
  Materialize `document_id` at `pin` and render it.

  Returns the rendered value, its content type, and the two foreign ids
  the destination records as provenance — *citation, never recomputed*.

  Errors are named rather than collapsed: `:not_on_chain` (the pin is
  not in this document's history), `:commit_not_found`,
  `{:trailing_bytes, n}` (a truncation this reader refuses to perform),
  and `{:unrenderable_content_type, t}` — a pin landing where the
  document held a type this seam cannot carry is a refusal, never a
  guess.

  `{:ok, []}` from the chain walk is legitimate, not a failure: a
  genesis pin replays nothing and IS the empty state.
  """
  @spec read_at(handle(), document_id(), commit_id()) :: {:ok, content()} | {:error, term()}
  def read_at(%{store: name}, document_id, pin)
      when is_binary(document_id) and is_binary(pin) do
    with {:ok, commits} <- chain(name, document_id, pin),
         {:ok, doc} <- replay_strict(commits),
         {:ok, type, bytes} <- render(doc) do
      {:ok,
       %{
         content_type: type,
         content: bytes,
         provenance: %{document_id: document_id, content_head: pin}
       }}
    end
  end

  # ── internals ────────────────────────────────────────────────────────

  # `DocBuilder.chain_to/4` is the same walk `Projection` verifies over —
  # sharing it is what makes "the chain we read" and "the chain anyone
  # else reads" one list by construction. It stops at the nearest
  # `:snapshot` commit (inclusive), so a full-state commit is never
  # replayed on top of its own ancestors.
  # ⛔ THE MEMBERSHIP GATE, and it is not belt-and-braces — `chain_to/4`
  # is DELIBERATELY DOC-AGNOSTIC: it is a pure `parent_id` walk, which is
  # what lets fork lineage be traversed at all. Handed a commit belonging
  # to a DIFFERENT document it walks that document's chain quite happily
  # and returns it. Without this check `read_at/3` would materialize one
  # document's content under another's `document_id` — precisely the
  # confusion the `{:doc_commit}` ownership key exists to prevent, and
  # precisely the trap this module's own docs warn about.
  #
  # Caught by the test, not by review: the refusal arm returned {:ok, _}.
  defp chain(name, document_id, pin) do
    if CommitStore.doc_has_commit?(name, document_id, pin) do
      case DocBuilder.chain_to(name, document_id, pin) do
        {:ok, commits} -> {:ok, commits}
        :none -> {:error, {:not_on_chain, pin}}
      end
    else
      {:error, {:not_on_chain, pin}}
    end
  end

  # ⛔ We replay here rather than calling `reconstruct_doc_at/4` for one
  # reason: that path applies updates through `Encoding.apply_update/2`,
  # which DISCARDS the decoder's trailing remainder. Strict decode cannot
  # be obtained by calling it, so the replay is reproduced with the check
  # in place. Same commits, same order — only the discard is removed.
  defp replay_strict(commits) do
    Enum.reduce_while(commits, {:ok, Doc.new()}, fn %Commit{} = c, {:ok, doc} ->
      case decode_strict(c.update) do
        {:ok, :empty} ->
          {:cont, {:ok, doc}}

        # Decoded twice on purpose: `decode_update/1` is the only place
        # the trailing remainder is visible, and `apply_update/2` is the
        # only public way to integrate. The extra decode buys the strict
        # check with no reach into yelixer's private integrate path.
        :ok ->
          case Encoding.apply_update(doc, c.update) do
            {:ok, next} -> {:cont, {:ok, next}}
            other -> {:halt, {:error, {:apply_failed, other}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_strict(<<>>), do: {:ok, :empty}

  defp decode_strict(update) do
    case Encoding.decode_update(update) do
      {:ok, {_items, _ds, <<>>}} ->
        :ok

      {:ok, {_items, _ds, rest}} ->
        {:error, {:trailing_bytes, byte_size(rest)}}

      other ->
        {:error, {:decode_failed, other}}
    end
  end

  # ── rendering, with CRDT GRANULARITY PRESERVED ───────────────────────
  #
  # ⛔ WHY THIS IS NOT `ContentType.get_content/1` + `CanonicalJson.encode/1`.
  #
  # A flat JSON render cannot distinguish a NESTED Y-TYPE from a PLAIN
  # value stored in a slot: `set("a", %{"k" => 1})` and `set("a",` a
  # nested YMap holding `k => 1`) both render `{"a":{"k":1}}`. The values
  # survive; the MERGE BEHAVIOUR does not. Two writers editing different
  # keys of a nested YMap both survive; the same edits against a plain
  # value are last-writer-wins and one is lost.
  #
  # ⇒ A flat import silently re-chooses the merge semantics of every
  # nested structure, invisibly at import time and visible only as LOST
  # EDITS the first time two people edit an imported document. Same
  # family as the trailing-bytes defect: correct-looking, undetectable
  # afterwards, failing toward silence.
  #
  # ⭐ And the distinction is ALREADY IN THE DATA — `{:type, ref}` vs
  # `{:any, [v]}` at the item level — becoming indistinguishable only
  # AFTER the render flattens it. So flattening here would DESTROY a
  # visible distinction, not fail to recover a lost one.
  #
  # ⚠️ COUPLING, DELIBERATE AND PINNED: this is the FIRST code in
  # commonplace to read `Yelixer.BlockStore` / `%Yelixer.Item{}` /
  # `doc.types` directly. There is no public yelixer API that exposes
  # the nested-vs-plain distinction, and yelixer is a separate public
  # repository this adapter cannot change. The coupling is confined to
  # the three functions below and pinned by
  # `monolith_reader_test.exs`'s granularity arms — if yelixer's item
  # shape or sub-type naming moves, those fail loudly rather than this
  # silently reverting to flat output.
  #
  # Wire shape (canonical JSON, so it crosses the repo boundary):
  #     {"t":"value","v":<json>}   a plain value
  #     {"t":"ymap","v":{...}}     a nested YMap, recursively tagged
  #     {"t":"yarray","v":[...]}   a nested YArray, recursively tagged
  #     {"t":"ytext","v":"..."}    a nested YText
  defp render(doc) do
    case ContentType.get_type(doc) do
      :text ->
        {:ok, :text, ContentType.get_content(doc) || ""}

      :map ->
        with {:ok, tagged} <- tagged_map(doc, @content_key),
             do: {:ok, :map, CanonicalJson.encode(tagged)}

      :array ->
        with {:ok, tagged} <- tagged_array(doc, @content_key),
             do: {:ok, :array, CanonicalJson.encode(tagged)}

      other ->
        {:error, {:unrenderable_content_type, other}}
    end
  end

  defp tagged_map(doc, type_key) do
    doc
    |> items_for(type_key)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub != nil end)
    |> reduce_ok(%{}, fn %Item{parent_sub: key} = item, acc ->
      with {:ok, node} <- tagged_value(doc, item), do: {:ok, Map.put(acc, key, node)}
    end)
  end

  defp tagged_array(doc, type_key) do
    doc
    |> items_for(type_key)
    |> Enum.reject(& &1.deleted)
    |> Enum.filter(fn %Item{parent_sub: sub} -> sub == nil end)
    |> reduce_ok([], fn item, acc ->
      with {:ok, node} <- tagged_value(doc, item), do: {:ok, [node | acc]}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # A plain value keeps its JSON; a nested sub-type is resolved by the
  # SAME dispatch yelixer's own `sub_type_to_json/2` uses — the synthetic
  # `__sub:CLIENT:CLOCK` key into `doc.types` — but tagged and recursed
  # instead of flattened.
  defp tagged_value(doc, %Item{content: {:any, [single]}}),
    do: {:ok, %{"t" => "value", "v" => Types.resolve_content_value(doc, single)}}

  defp tagged_value(doc, %Item{content: {:any, list}}),
    do: {:ok, %{"t" => "value", "v" => Enum.map(list, &Types.resolve_content_value(doc, &1))}}

  defp tagged_value(_doc, %Item{content: {:string, s}}), do: {:ok, %{"t" => "value", "v" => s}}
  defp tagged_value(_doc, %Item{content: {:embed, v}}), do: {:ok, %{"t" => "value", "v" => v}}

  defp tagged_value(doc, %Item{content: {:type, _ref}, id: %ID{client: c, clock: k}}) do
    sub_key = "__sub:#{c}:#{k}"

    case Map.get(doc.types, sub_key) do
      :map ->
        with {:ok, m} <- tagged_map(doc, sub_key), do: {:ok, %{"t" => "ymap", "v" => m}}

      :array ->
        with {:ok, a} <- tagged_array(doc, sub_key), do: {:ok, %{"t" => "yarray", "v" => a}}

      :text ->
        {:ok, %{"t" => "ytext", "v" => Types.Text.to_string(doc, sub_key)}}

      # ⛔ REFUSE rather than silently flatten. Falling back to a flat
      # render here would reintroduce exactly the defect this walk exists
      # to prevent, at the one moment nobody is watching.
      other ->
        {:error, {:unknown_subtype_kind, other, sub_key}}
    end
  end

  defp tagged_value(_doc, %Item{content: other}),
    do: {:error, {:unrenderable_item_content, elem_tag(other)}}

  defp elem_tag(t) when is_tuple(t) and tuple_size(t) > 0, do: elem(t, 0)
  defp elem_tag(other), do: other

  defp items_for(doc, type_key), do: BlockStore.get_sequence(doc.store, type_key)

  defp reduce_ok(list, init, fun) do
    Enum.reduce_while(list, {:ok, init}, fn el, {:ok, acc} ->
      case fun.(el, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp cub_bytes(store_dir) do
    store_dir
    |> Path.join("*.cub")
    |> Path.wildcard()
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end
end
