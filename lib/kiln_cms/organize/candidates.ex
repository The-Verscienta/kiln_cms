defmodule KilnCMS.Organize.Candidates do
  @moduledoc """
  The bounded, actor-authorized document set every `KilnCMS.Organize` surface
  starts from (#1596).

  **Authorization first, vectors second.** Each surface lists the documents
  the actor may read *before* it reads a single embedding, and then reads
  vectors for exactly those ids. That is the opposite order from
  `KilnCMS.Search.Related`'s per-document panel (nearest neighbours over the
  whole index, then hydrate each hit as the caller), and it is the order a
  library-level surface needs: no per-hit read (`ContentTypes.get_record/3`
  once per neighbour would be an N+1 across hundreds of documents), and no
  path by which a vector — or the title it hydrates to — of a document the
  actor cannot read reaches them. A granular-RBAC editor (#332) without a
  type simply gets no rows of it: the type's read policy filters them here.

  Rows are narrow maps, newest first across every content type:
  `%{id, type, storage, title, slug, state, updated_at, category_id, tags}` —
  `type` the public type name (the editor URL's segment), `storage` the
  embedding index's `document_type` (`:page`/`:post`/`:entry`).
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Organize.Terms

  @fields [:id, :title, :slug, :state, :updated_at]

  @typedoc "A candidate document."
  @type t :: %{
          id: Ash.UUID.t(),
          type: String.t(),
          storage: atom(),
          title: String.t() | nil,
          slug: String.t(),
          state: atom(),
          updated_at: DateTime.t(),
          category_id: Ash.UUID.t() | nil,
          tags: list()
        }

  @doc """
  Up to `:limit` documents the actor may read, newest first. Options:

    * `:limit` (required) — the bound; each type is read with it too, so the
      merge never holds more than `types × limit` rows;
    * `:state` — `:published`, `:draft`, `:in_review`, or `:any` (default);
    * `:filter` — an extra Ash filter expression (`Terms.untermed_filter/0`);
    * `:type` — one public type name, or `nil` for every type.
  """
  @spec list(term(), term(), keyword()) :: [t()]
  def list(org, actor, opts) do
    limit = Keyword.fetch!(opts, :limit)
    filters = filters(opts)

    org
    |> ContentTypes.all_for_org()
    |> only_type(Keyword.get(opts, :type))
    |> Enum.flat_map(fn ct ->
      storage = ContentTypes.storage_type(ct, KilnCMS.Accounts.org_id(org))

      ContentTypes.list!(ct,
        actor: actor,
        tenant: org,
        query:
          filters ++
            [select: @fields ++ Terms.term_fields(), sort: [updated_at: :desc], limit: limit],
        load: Terms.term_load()
      )
      |> Enum.map(&row(&1, to_string(ct.type), storage))
    end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  `list/3`, plus whether the bound cut anything off: `%{rows:, truncated?:}`.
  Reads one row past `:limit` to know. A surface that shows a bounded set
  says so when `truncated?` — a bound is only stated if the editor can see it.
  """
  @spec bounded(term(), term(), keyword()) :: %{rows: [t()], truncated?: boolean()}
  def bounded(org, actor, opts) do
    limit = Keyword.fetch!(opts, :limit)
    rows = list(org, actor, Keyword.put(opts, :limit, limit + 1))
    %{rows: Enum.take(rows, limit), truncated?: length(rows) > limit}
  end

  @doc "The editor URL path for a candidate row."
  @spec editor_path(t()) :: String.t()
  def editor_path(%{type: type, id: id}), do: "/editor/content/#{type}/#{id}"

  defp filters(opts) do
    state =
      case Keyword.get(opts, :state, :any) do
        :any -> []
        state when state in [:published, :draft, :in_review] -> [filter: [state: state]]
      end

    extra = if f = opts[:filter], do: [filter: f], else: []
    state ++ extra
  end

  defp only_type(types, nil), do: types
  defp only_type(types, type), do: Enum.filter(types, &(to_string(&1.type) == type))

  defp row(record, type, storage) do
    %{
      id: record.id,
      type: type,
      storage: storage,
      title: record.title,
      slug: record.slug,
      state: record.state,
      updated_at: record.updated_at,
      category_id: record.category_id,
      tags: record.tags
    }
  end
end
