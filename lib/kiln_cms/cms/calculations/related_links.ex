defmodule KilnCMS.CMS.Calculations.RelatedLinks do
  @moduledoc """
  The record's curated "related" links as `[%{id, title, slug}]` (#996).

  A projection, and that is the whole point. The MCP write tools need to echo
  which related links a write left behind, so a model can tell a
  `remove_related_*_ids` that matched nothing from one that detached something —
  the same gap #640 closed for tags.

  `load` could not do it. `AshAi.Serializer` emits
  `default_attributes(resource) ++ load_fields` — an append — and Ash's load of
  an attribute is an ensure-selected no-op, so `load [related_posts: [:id,
  :title]]` reads like a field list while serializing every public attribute of
  every related post, bodies included. On a post with a handful of related items
  that is kilobytes per write, charged to the model's context.

  A calculation is serialized as its own value, so this returns exactly three
  fields and cannot widen when a content attribute is added.

  The list is in the editor's order (#2025): each link's `position`. The
  `related_<type>s` relationship itself is not — Ash orders a many-to-many
  load by its destination, and `ContentLink` is not unique on
  `(source_id, target_id)`, which a sort reaching the join row would need —
  so this is the read that carries the order to API and MCP callers.

  Takes the relationship name because the shared `Content` macro mints a
  different one per type (`related_pages` / `related_posts` / `related_entries`)
  — passing it beats three near-identical modules.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.CMS.ContentLinks

  @impl true
  def init(opts) do
    case opts[:relationship] do
      name when is_atom(name) and not is_nil(name) ->
        {:ok, opts}

      other ->
        {:error,
         "`:relationship` must be the related many_to_many's name, got: #{inspect(other)}"}
    end
  end

  # Only the three fields projected below, so the join reads three columns
  # rather than every attribute of the related resource.
  @impl true
  def load(_query, opts, _context), do: [{opts[:relationship], [:id, :title, :slug]}]

  @impl true
  def calculate(records, opts, _context) do
    relationship = opts[:relationship]

    # In the editor's order (#2025): a load of the many-to-many does not
    # follow the links' `position`, so the projection sorts by it.
    records
    |> ContentLinks.sort_related_all(relationship)
    |> Enum.map(fn record ->
      record
      |> Map.get(relationship)
      |> List.wrap()
      |> Enum.reject(&match?(%Ash.NotLoaded{}, &1))
      |> Enum.map(&%{id: &1.id, title: &1.title, slug: &1.slug})
    end)
  end
end
