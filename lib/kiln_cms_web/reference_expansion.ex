defmodule KilnCMSWeb.ReferenceExpansion do
  @moduledoc """
  `?expand=` on `GET /api/content/:type/:slug` (relationships plan, R7): the
  targets of a document's `:reference` custom fields, each with its own fired
  `json` artifact, in one response.

      GET /api/content/post/pancakes?expand=ingredients,related

  adds one key to the `json` artifact:

      "expanded": {
        "ingredients": [
          {"position": 0, "link": {}, "id": "…", "type": "ingredient",
           "slug": "flour", "target": { …flour's json artifact… }},
          …
        ],
        "related": []
      }

  ## Why here and not as JSON:API `included` members

  §7 Q1 asked for a spike of `?include=content_links.target` first: a
  polymorphic `target` on `ContentLink`, emitted as heterogeneous `included`
  members. AshJsonApi cannot do that without patching it.
  `AshJsonApi.Includes.Parser` accepts an include path only when every
  segment is a *public relationship* (`Ash.Resource.Info.public_relationship/2`),
  and an Ash relationship has exactly one destination resource, so a
  calculation named `target` is refused as an invalid include. The nearest
  thing that does work, one relationship per target resource
  (`target_page`, `target_post`, `target_entry`, …), is a different URL
  shape, and `ContentLink` would have to list every content type, a project
  overlay's included, which `config/project.exs` should never have to touch.
  So the delivery API answers it instead. The JSON:API surface keeps
  `?include=content_links`, which carries each edge's `target_id` and
  `target_type`.

  ## Who sees what

  Delivery is actorless (see `KilnCMSWeb.ArtifactController`), and so is the
  expansion. The source has already been resolved as published and readable
  by the delivery read. A target is expanded only when an **anonymous** reader
  may read it, through its type's own read policy: published, public, not
  passphrase-locked. A draft, gated or locked target is left out, exactly as
  if the edge were not there, even when the request carries an unlock grant
  for the source. The response stays the same for everyone at the URL, so it
  keeps its public cache headers.

  ## Cost

  An expanded response is not served from the artifact cache alone: it reads
  the source's edges, one read per target type, and each target's artifact
  (cache-first). At most 10 fields per request and 100 targets per
  field. A target published but not fired yet has `"target": null`, and a
  firing job is queued for it, as a direct read would.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.Delivery
  alias KilnCMS.Firing.Engine

  @max_fields 10
  @max_rows 100

  @doc """
  Reads `?expand=` from the query params: `{:ok, nil}` when absent or blank,
  `{:ok, fields}` for a comma-separated list of field names, or
  `{:error, message}`.
  """
  @spec parse(map()) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  def parse(%{"expand" => value}) when is_binary(value) do
    fields =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      fields == [] -> {:ok, nil}
      length(fields) > @max_fields -> {:error, "`expand` takes at most #{@max_fields} fields."}
      true -> {:ok, fields}
    end
  end

  def parse(%{"expand" => _not_a_string}),
    do: {:error, "`expand` must be a comma-separated list of field names."}

  def parse(_params), do: {:ok, nil}

  @doc """
  The expansion of `fields` on `record` (a published document of `org_id`):
  `{:ok, expanded, tag}`, where `expanded` maps every requested field to its
  list (empty when the field has no readable targets) and `tag` changes
  whenever any expanded target does, for the response's ETag. `:unavailable`
  when the database cannot be reached.
  """
  @spec expand(struct(), [String.t()], Ash.UUID.t()) ::
          {:ok, %{String.t() => [map()]}, non_neg_integer()} | :unavailable
  def expand(record, fields, org_id) do
    edges = edges(record, fields, org_id)
    targets = readable_targets(edges, org_id)

    expanded =
      edges
      |> Enum.filter(&Map.has_key?(targets, &1.target_id))
      |> Enum.group_by(& &1.field)
      |> Map.new(fn {field, edges} -> {field, Enum.take(edges, @max_rows)} end)

    included = expanded |> Map.values() |> List.flatten()
    tag = :erlang.phash2({fields, Enum.map(included, &tag_part(targets[&1.target_id]))})

    {:ok,
     Map.new(fields, fn field ->
       {field, expanded |> Map.get(field, []) |> Enum.map(&entry(&1, targets, org_id))}
     end), tag}
  rescue
    error ->
      if Delivery.db_unavailable?(error), do: :unavailable, else: reraise(error, __STACKTRACE__)
  end

  # The source has already passed the delivery read, so its edges are read
  # without a second authorization. Their targets are gated below.
  defp edges(record, fields, org_id) do
    CMS.list_content_links!(
      query: [
        filter: [source_id: record.id, kind: :reference, field: [in: fields]],
        sort: [field: :asc, position: :asc, id: :asc]
      ],
      authorize?: false,
      tenant: org_id
    )
  end

  # `%{id => record}` of the edges' targets an anonymous reader may read, one
  # read per target type.
  defp readable_targets(edges, org_id) do
    edges
    |> Enum.group_by(& &1.target_type, & &1.target_id)
    |> Enum.flat_map(fn {type_name, ids} -> read_targets(type_name, Enum.uniq(ids), org_id) end)
    |> Map.new(&{&1.id, &1})
  end

  defp read_targets(nil, _ids, _org_id), do: []

  defp read_targets(type_name, ids, org_id) do
    opts = [query: [filter: [id: [in: ids]]], actor: nil, authorize?: true, tenant: org_id]

    case ContentTypes.get(type_name, org_id) do
      %{source: :dynamic} -> CMS.list_entries!(opts)
      %{resource: resource} when not is_nil(resource) -> ContentTypes.list!(type_name, opts)
      _unknown -> []
    end
  end

  defp tag_part(target), do: {target.id, target.updated_at}

  defp entry(edge, targets, org_id) do
    target = Map.fetch!(targets, edge.target_id)

    %{
      "position" => edge.position,
      "link" => edge.metadata,
      "id" => target.id,
      "type" => edge.target_type,
      "slug" => target.slug,
      "target" => artifact(target, org_id)
    }
  end

  defp artifact(target, org_id) do
    type = Engine.document_type(target)

    case Delivery.read_artifact(org_id, type, target.id, :json) do
      {:ok, body} ->
        body

      :miss ->
        enqueue_backfill(org_id, type, target.id)
        nil

      :unavailable ->
        nil
    end
  end

  defp enqueue_backfill(org_id, type, id) do
    %{"org_id" => org_id, "type" => to_string(type), "id" => id}
    |> KilnCMS.Firing.FireWorker.new()
    |> Oban.insert()
  end
end
