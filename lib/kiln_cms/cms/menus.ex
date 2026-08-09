defmodule KilnCMS.CMS.Menus do
  @moduledoc """
  Delivery-side resolution of a navigation menu (#466): the flat
  `KilnCMS.CMS.MenuItem` rows of one menu, folded into a tree with every
  destination resolved to a **live URL**.

  Two things happen here that can't happen in the stored rows:

    * a `:content` item's URL is computed from the target's *current* published
      path, so a slug rename moves the nav with it and never leaves a dead link
      — the same live-resolution contract `KilnCMS.CMS.Redirects` has, and the
      reason the item stores a reference rather than a path;
    * an item whose target isn't visible to the caller is **dropped**, with its
      subtree, rather than rendered as a link to a 404. An unpublished, trashed
      or deleted target is invisible to everyone; that is the whole
      "published-content visibility rules apply" requirement, and it has to live
      here because the stored row has no idea who is asking.

  One read per content type plus one for the items, regardless of tree size:
  nav sits on the anonymous delivery path and must not cost a query per link.

  ## What a cycle does here

  Stored data can hold a cycle that the write-time guards didn't catch — two
  editors re-parenting concurrently each validate against pre-commit state. The
  walk is safe regardless: it descends only from `parent_id == nil` and emits
  each node under its single parent, so a cycle's members are simply unreachable
  from any root and vanish from the served tree. That is silent data loss, not a
  hang — the guards exist to keep an editor's menu intact, not to keep delivery
  alive.
  """

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Menu
  alias KilnCMS.CMS.MenuItem
  alias KilnCMS.CMS.Slugs

  @typedoc """
  A resolved menu node: the item's own fields plus `url` (nil for a `:none`
  heading) and its resolved `children`.
  """
  @type node_map :: %{
          id: Ash.UUID.t(),
          label: String.t(),
          url: String.t() | nil,
          link_type: atom(),
          open_in_new_tab: boolean(),
          children: [node_map()]
        }

  @doc """
  The menu `key` in `locale`, resolved for `org_id` — `{:ok, menu, tree}`, or
  `:not_found` when no such menu exists for that locale.

  A missing locale variant is deliberately **not** a fallback to the default
  locale: serving English navigation on a French page is a worse answer than
  serving none, and only the caller knows which it prefers.

  ## Options

    * `:audiences` — which audience tiers the reader holds. Because this read
      runs `authorize?: false`, its filter is the sole security boundary, so it
      gates the audience axis too, not just publish state (`Content`'s rule for
      exactly this shape). Defaults to `[:public]`, which is what an anonymous
      caller gets — the same answer the sitemap and the feeds give. A front end
      that has authenticated its reader can widen it.
    * `:include_hidden?` — keep items an editor switched off and items whose
      target isn't published. For the editor's own preview of a menu; never for
      delivery. Defaults to `false`.
  """
  @spec resolve(String.t(), String.t(), Ash.UUID.t(), keyword()) ::
          {:ok, Menu.t(), [node_map()]} | :not_found
  def resolve(key, locale, org_id, opts \\ []) do
    case CMS.get_menu_by_key!(key, locale,
           authorize?: false,
           tenant: org_id,
           not_found_error?: false
         ) do
      nil -> :not_found
      menu -> {:ok, menu, tree(menu, org_id, opts)}
    end
  end

  @doc """
  The menu's items that **no chain of parents reaches a root from** (#900).

  `build/3` descends from `parent_id == nil` and emits each item under its one
  parent, so an item in a parent cycle is not rendered anywhere: it and its
  whole subtree disappear from the served menu *and* from the editor's tree, with
  no error and no row deleted. The editor's only signal is "my navigation section
  vanished", and because the items aren't rendered they cannot be selected,
  edited or outdented back into place.

  A cycle can be committed by two editors re-parenting at the same time —
  `Validations.MenuItemPlacement` walks the ancestor chain with plain reads
  outside any lock, so under READ COMMITTED each validates against pre-commit
  state and neither sees the other's write. This does not close that race; it
  makes the outcome visible and recoverable, which also covers a cycle arriving
  from a restore or direct SQL.

  Purely structural, and deliberately **not** filtered by `keep?/3`: an item
  hidden by an editor, or one whose target is unpublished, is legitimately
  absent from a rendered tree and is not detached. The question here is only
  whether following `parent_id` terminates at a root within this menu.
  """
  @spec detached(Menu.t(), Ash.UUID.t()) :: [MenuItem.t()]
  def detached(menu, org_id) do
    MenuItem
    |> Ash.Query.filter(menu_id == ^menu.id)
    |> Ash.Query.sort(position: :asc, label: :asc)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> detached()
  end

  @doc """
  `detached/2` over rows the caller already has.

  The builder reads this menu's items to render the tree anyway, and reading
  them a second time to answer a purely in-memory question would be a query per
  reorder, indent, outdent and save.
  """
  @spec detached([MenuItem.t()]) :: [MenuItem.t()]
  def detached(items) when is_list(items) do
    by_id = Map.new(items, &{&1.id, &1})
    Enum.reject(items, &rooted?(&1, by_id, []))
  end

  # Walks up rather than down, so it answers per item without building a tree.
  # `seen` is what makes it terminate: a cycle revisits an id it already passed
  # through, which is exactly the condition being detected.
  #
  # A plain list, not a `MapSet`. Threading one through a recursive call means
  # two construction paths reach the same parameter — `MapSet.new/0` at the top
  # and `MapSet.put/2` below — and OTP 29's dialyzer reads that as an opacity
  # violation. `.tool-versions` records why that matters: CI runs OTP 27, whose
  # opacity checking is weaker, so this class is invisible there and only a
  # local `mix dialyzer` catches it. A chain here is `max_depth()` long when the
  # data is sound and terminates on the revisit when it is not, so a linear
  # membership test costs nothing worth a MapSet.
  defp rooted?(%{parent_id: nil}, _by_id, _seen), do: true

  defp rooted?(%{id: id, parent_id: parent_id}, by_id, seen) do
    if id in seen do
      false
    else
      # A parent outside this menu's item set (deleted, or belonging to another
      # menu) is not a root either — nothing renders through it.
      case Map.get(by_id, parent_id) do
        nil -> false
        parent -> rooted?(parent, by_id, [id | seen])
      end
    end
  end

  @doc """
  The resolved tree for an already-loaded `menu`. Takes the same options as
  `resolve/4`.
  """
  @spec tree(Menu.t(), Ash.UUID.t(), keyword()) :: [node_map()]
  def tree(menu, org_id, opts \\ []) do
    include_hidden? = Keyword.get(opts, :include_hidden?, false)

    items =
      MenuItem
      |> Ash.Query.filter(menu_id == ^menu.id)
      |> Ash.Query.sort(position: :asc, label: :asc)
      |> Ash.read!(authorize?: false, tenant: org_id)

    urls = resolve_urls(items, org_id, opts)

    # Grouped once, not re-filtered per node: `build/3` used to scan the whole
    # item list at every level, which is O(n^2) on a read anonymous traffic can
    # ask for. `group_by` preserves the sorted order within each bucket.
    by_parent =
      items
      |> Enum.filter(&keep?(&1, urls, include_hidden?))
      |> Enum.group_by(& &1.parent_id)

    build(by_parent, nil, urls)
  end

  # An editor-hidden item is out unless the caller asked for hidden ones; a
  # `:content` item with no resolved URL is out because its target isn't
  # published (or is gone). `:url` and `:none` items have nothing to check.
  defp keep?(_item, _urls, true), do: true
  defp keep?(%{visible: false}, _urls, _include), do: false
  defp keep?(%{link_type: :content} = item, urls, _include), do: Map.has_key?(urls, item.id)
  defp keep?(_item, _urls, _include), do: true

  # Fold the surviving flat rows into a tree. An item whose parent was filtered
  # out never appears: `build/3` only descends from parents it kept, so a
  # dropped section takes its links with it rather than promoting them to the
  # top level, which is what an "omit unpublished" rule has to mean visually.
  defp build(by_parent, parent_id, urls) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(fn item ->
      %{
        id: item.id,
        label: item.label,
        url: url_for(item, urls),
        link_type: item.link_type,
        open_in_new_tab: item.open_in_new_tab,
        children: build(by_parent, item.id, urls)
      }
    end)
  end

  defp url_for(%{link_type: :content} = item, urls), do: Map.get(urls, item.id)
  defp url_for(%{link_type: :url, url: url}, _urls), do: url
  defp url_for(_item, _urls), do: nil

  # `%{item_id => path}` for every `:content` item whose target is currently
  # published — one read per distinct content type, not one per item. An
  # unknown type (deleted since the item was authored) simply contributes
  # nothing, so those items drop out with the unpublished ones.
  defp resolve_urls(items, org_id, opts) do
    items
    |> Enum.filter(&(&1.link_type == :content and not is_nil(&1.target_id)))
    |> Enum.group_by(& &1.target_type)
    |> Enum.flat_map(fn {type, group} -> urls_for_type(type, group, org_id, opts) end)
    |> Map.new()
  end

  defp urls_for_type(type, group, org_id, opts) do
    case ContentTypes.get(type, org_id) do
      nil ->
        []

      ct ->
        ids = group |> Enum.map(& &1.target_id) |> Enum.uniq()
        published = published_paths(ct, ids, org_id, opts)

        for item <- group, path = published[item.target_id], do: {item.id, path}
    end
  end

  # The canonical path of each published target: its `path_alias` (#485) when
  # set, else `/<prefix>/<slug>` — exactly what delivery serves, so nav never
  # links to a URL that would immediately 301.
  defp published_paths(ct, ids, org_id, opts) do
    audiences = Keyword.get(opts, :audiences, [:public])

    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id in ^ids and state == :published and audience in ^audiences)
    |> Ash.Query.select([:id, :slug, :path_alias])
    |> scope_dynamic(ct)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> Map.new(&{&1.id, Slugs.public_path_for(ct, &1)})
  end

  # Dynamic types share the `Entry` table, so a bare id read could cross types.
  defp scope_dynamic(query, %{source: :dynamic, definition: definition}),
    do: Ash.Query.filter(query, type_definition_id == ^definition.id)

  defp scope_dynamic(query, _compiled), do: query
end
