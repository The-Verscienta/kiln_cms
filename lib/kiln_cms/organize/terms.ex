defmodule KilnCMS.Organize.Terms do
  @moduledoc """
  The one seam between derived organization (#1596) and today's vocabulary.

  1.1 ships `KilnCMS.Organize` against `KilnCMS.CMS.Tag` and
  `KilnCMS.CMS.Category`; 2.0 collapses both into one hierarchical term
  vocabulary (#1595). That rework is accepted rather than avoided, and this
  module is how it stays small: nothing else in `KilnCMS.Organize` or
  `KilnCMSWeb.OrganizeLive` names `Tag`, `Category`, a `tags` relationship or a
  `category_id`. Migrating means rewriting this file.

  A term here is a plain map — `%{id, kind: :tag | :category, name, slug}` —
  never the resource struct, so callers cannot grow a dependency on a field
  the 2.0 term will not have.

  ## Vectors are tags-only

  Only tag names are embedded (`KilnCMS.Search.TagEmbedding`). Categories have
  no vector, so every distance-based signal ("near-duplicate terms", "far from
  every tag") is about tags and says so.

  ## Usage counts live content only

  The public `page_count`/`post_count` aggregates count trashed documents too
  (an aggregate does not run its destination's archival filter). For health
  that would hide the term whose last remaining use is in the trash, so
  `usage/3` reads the private `live_*_count` aggregates instead — the same
  counts minus the trash — and a media item counts for a tag as it does on the
  taxonomy page. Counts are read **as the actor**: an aggregate authorizes its
  destination, so a granular-RBAC editor's counts leave out the types they were
  not given, exactly like the taxonomy page's own counts.

  ## Bounds

  `tags/2`, `categories/2` and `usage/2` read at most
  `KilnCMS.Organize.bound(:term_limit)` (500) terms each, by name — a larger
  vocabulary is reported on its first 500, and the console says so. Types the
  private aggregates do not cover (compiled types from `mix kiln.gen.content`)
  cost one count per *suspect* term (usage 0 or 1) per such type, so at most
  `2 × 500 × extra types` queries on a fresh vocabulary, and none on a stock
  install.
  """
  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.Search.Related

  @typedoc "A vocabulary term, independent of the resource that stores it."
  @type t :: %{id: Ash.UUID.t(), kind: :tag | :category, name: String.t(), slug: String.t()}

  # Types the private aggregates already count. Every other compiled content
  # type (`mix kiln.gen.content`) is counted with one query per suspect term.
  @aggregated_types [:page, :post]

  @doc "The actor's tags, by name — at most `KilnCMS.Organize.bound(:term_limit)`."
  @spec tags(term(), term()) :: [t()]
  def tags(org, actor) do
    CMS.list_tags!(
      actor: actor,
      tenant: org,
      query: [select: [:id, :name, :slug], sort: [name: :asc], limit: limit()]
    )
    |> Enum.map(&to_term(&1, :tag))
  end

  @doc "The actor's categories, by name — same bound as `tags/2`."
  @spec categories(term(), term()) :: [t()]
  def categories(org, actor) do
    CMS.list_categories!(
      actor: actor,
      tenant: org,
      query: [select: [:id, :name, :slug], sort: [name: :asc], limit: limit()]
    )
    |> Enum.map(&to_term(&1, :category))
  end

  @doc """
  Every term with its live usage — `[{term, count}]`, tags then categories.
  See the moduledoc for what counts.
  """
  @spec usage(term(), term()) :: [{t(), non_neg_integer()}]
  def usage(org, actor) do
    tags =
      CMS.list_tags!(
        actor: actor,
        tenant: org,
        query: [sort: [name: :asc], limit: limit()],
        load: [:live_page_count, :live_post_count, :live_entry_count, :media_count]
      )
      |> Enum.map(fn tag ->
        {to_term(tag, :tag),
         tag.live_page_count + tag.live_post_count + tag.live_entry_count + tag.media_count}
      end)

    categories =
      CMS.list_categories!(
        actor: actor,
        tenant: org,
        query: [sort: [name: :asc], limit: limit()],
        load: [:live_page_count, :live_post_count, :live_entry_count]
      )
      |> Enum.map(fn category ->
        {to_term(category, :category),
         category.live_page_count + category.live_post_count + category.live_entry_count}
      end)

    refine_extra_types(tags ++ categories, org, actor)
  end

  # Only a term the aggregates put at 0 or 1 can be unused or single-use, so
  # only those are worth a query per extra compiled type — on a stock install
  # there are none, and this is free.
  defp refine_extra_types(counted, org, actor) do
    case extra_types() do
      [] ->
        counted

      types ->
        Enum.map(counted, fn
          {term, n} when n <= 1 -> {term, n + extra_usage(term, types, org, actor)}
          other -> other
        end)
    end
  end

  defp extra_types,
    do: ContentTypes.all() |> Enum.reject(&(&1.type in @aggregated_types))

  defp extra_usage(term, types, org, actor) do
    filter = usage_filter(term)

    Enum.reduce(types, 0, fn ct, acc ->
      acc + ContentTypes.count!(ct, actor: actor, tenant: org, query: [filter: filter])
    end)
  end

  defp usage_filter(%{kind: :tag, id: id}), do: expr(exists(tags, id == ^id))
  defp usage_filter(%{kind: :category, id: id}), do: expr(category_id == ^id)

  @doc """
  The filter for a document carrying no term at all — no tags and no
  category — for `ContentTypes.list!/2`'s `query: [filter: …]`.
  """
  @spec untermed_filter() :: Ash.Expr.t()
  def untermed_filter, do: expr(is_nil(category_id) and not exists(tags, true))

  @doc """
  Which kinds of term a listed document lacks: `:none` (no tags, no
  category), `:no_tags` or `:no_category`. Needs `:category_id` selected and
  `:tags` loaded (`untermed_fields/0`, `term_load/0`).
  """
  @spec missing(map()) :: :none | :no_tags | :no_category | :complete
  def missing(doc) do
    case {applied_tag_ids(doc) == [], is_nil(Map.get(doc, :category_id))} do
      {true, true} -> :none
      {true, false} -> :no_tags
      {false, true} -> :no_category
      {false, false} -> :complete
    end
  end

  @doc "The fields `missing/1` reads, for a narrow `select:`."
  @spec term_fields() :: [atom()]
  def term_fields, do: [:category_id]

  @doc "The relationship load `applied_tag_ids/1` reads."
  @spec term_load() :: keyword()
  def term_load, do: [tags: [:id]]

  @doc """
  The tag ids a document carries **as the editor sees it**: the working
  copy's held set when it holds one (docs/working-copy.md), else its live
  tags. A tag already ticked in a pending working copy is applied, as far as
  a reviewer is concerned — proposing it again would be noise.
  """
  @spec applied_tag_ids(map()) :: [String.t()]
  def applied_tag_ids(doc) do
    held =
      if Map.has_key?(doc, :working_fields), do: WorkingCopy.held_ids(doc, :tag_ids)

    held || live_tag_ids(doc)
  end

  defp live_tag_ids(%{tags: tags}) when is_list(tags), do: Enum.map(tags, &to_string(&1.id))
  defp live_tag_ids(_doc), do: []

  @doc """
  Stored tag-name vectors, `%{tag_id => [float]}`, for the given tags —
  current rows only (a vector computed for a previous name is left out, the
  same rule `Related.suggest_tags/2` applies). Reads the index as the search
  system actor; never infers.
  """
  @spec tag_vectors(term(), [t()]) :: %{Ash.UUID.t() => [float()]}
  def tag_vectors(_org, []), do: %{}

  def tag_vectors(org, tags) do
    names = Map.new(tags, &{&1.id, &1.name})

    KilnCMS.SearchIndex.tag_embeddings_for!(Map.keys(names),
      # The tag-embedding index admits the search system actor (#1402); only
      # ids and vectors come back, for tags the caller already listed.
      actor: KilnCMS.SystemActor.new(:search),
      tenant: KilnCMS.Accounts.org_id(org)
    )
    |> Enum.filter(&(is_list(&1.embedding) and Map.get(names, &1.tag_id) == &1.name))
    |> Map.new(&{&1.tag_id, &1.embedding})
  end

  @doc """
  How many of the actor's tags have no current stored vector, leaving out
  `exclude` (ids an earlier `index_tag_vectors/3` reported as failed). `0`
  when semantic search is off, without a database read.
  """
  @spec missing_tag_vectors(term(), term(), [Ash.UUID.t()]) :: non_neg_integer()
  def missing_tag_vectors(org, actor, exclude \\ []) do
    if KilnCMS.Organize.enabled?() do
      excluded = MapSet.new(exclude)

      org
      |> KilnCMS.Accounts.org_id()
      |> Related.missing_tag_vectors(tags(org, actor))
      |> Enum.count(&(not MapSet.member?(excluded, &1.id)))
    else
      0
    end
  end

  @doc """
  Fills the tag-vector index one chunk at a time, the chunk sized to the room
  **left** in the editor's embedding window
  (`KilnCMS.Search.embedding_remaining/3`), never to the window's full size:
  a charge larger than the room left is refused *and still counted* (Hammer
  increments before it compares), which would leave the editor's own
  per-document panel blocked for the rest of the window. With no room left it
  answers `{:error, {:rate_limited, window_ms}}` without charging anything.

  Interactive: an editor clicked for it. `exclude` is the `failed` ids earlier
  calls reported (see `KilnCMS.Search.Related.ensure_tag_vectors/3`), so a
  name the embedder cannot answer for stops being retried. Semantic search off
  answers `{:ok, %{indexed: 0, failed: [], remaining: 0}}` before any read.
  """
  @spec index_tag_vectors(term(), term(), [Ash.UUID.t()]) ::
          {:ok,
           %{indexed: non_neg_integer(), failed: [Ash.UUID.t()], remaining: non_neg_integer()}}
          | {:error, term()}
  def index_tag_vectors(org, actor, exclude \\ []) do
    if KilnCMS.Organize.enabled?(),
      do: index_chunk(org, actor, exclude),
      else: {:ok, %{indexed: 0, failed: [], remaining: 0}}
  end

  defp index_chunk(org, actor, exclude) do
    org_id = KilnCMS.Accounts.org_id(org)
    user_id = actor && actor.id

    case KilnCMS.Search.embedding_remaining(org_id, user_id, false) do
      0 ->
        {_count, window_ms} = KilnCMS.Search.embedding_per_user_limit()
        {:error, {:rate_limited, window_ms}}

      room ->
        opts = [user_id: user_id, exclude: exclude]
        opts = if room == :infinity, do: opts, else: Keyword.put(opts, :max, room)
        Related.ensure_tag_vectors(org_id, tags(org, actor), opts)
    end
  end

  @doc """
  Adds `tag_ids` to a document as `actor`, the way the editor would:

    * a draft or in-review document takes them on `:update` (`add_tag_ids`,
      the non-destructive merge verb — nothing already attached is touched);
    * a **published** one takes them into its working copy
      (`:save_working_copy`'s `fields`), merged against whatever tag set the
      copy already holds, so readers see nothing until *Publish changes*.

  `record` should be freshly read: both actions carry an optimistic lock.
  """
  @spec apply_tags(term(), struct(), [String.t()], term()) :: {:ok, struct()} | {:error, term()}
  def apply_tags(_type, record, [], _actor), do: {:ok, record}

  def apply_tags(type, %{state: :published} = record, tag_ids, actor) do
    ContentTypes.save_working_copy(type, record, %{fields: %{"add_tag_ids" => tag_ids}},
      actor: actor,
      tenant: record.org_id
    )
  end

  def apply_tags(type, record, tag_ids, actor) do
    ContentTypes.update(type, record, %{add_tag_ids: tag_ids},
      actor: actor,
      tenant: record.org_id
    )
  end

  defp to_term(record, kind),
    do: %{id: record.id, kind: kind, name: record.name, slug: record.slug}

  defp limit, do: KilnCMS.Organize.bound(:term_limit)
end
