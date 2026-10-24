defmodule KilnCMS.Firing.LiveBlog do
  @moduledoc """
  The `LiveBlogPosting` properties of a document's schema.org node (#2046).

  `LiveBlogPosting` is an Article-family type (it is a `BlogPosting`), so it
  keeps `headline`, `articleBody` and the CreativeWork dates. What it adds is
  coverage and updates:

    * `coverageStartTime` / `coverageEndTime` — from the document's first
      `datetime_range` field, the same field an Event's dates come from
      (`KilnCMS.Events.schedule_value/2`). With no range, coverage starts at
      `published_at` and has no end, which is what an ongoing story is.
    * `liveBlogUpdate` — a `BlogPosting` per published update, newest first,
      capped at `max_updates/0`.

  ## Where the updates come from

  Kiln has no `LiveUpdate` resource. An update is any record that points at
  the story through a `:reference` field with another side (`inverse_label`,
  R4 — `KilnCMS.CMS.ReverseFields`): the story type's **first** reverse field
  is its update stream, the way the first `datetime_range` is an event's
  schedule. A `LiveStory` type with a `live_update` type whose `story`
  reference is labelled "Updates" is the whole setup.

  The updates are read from the source records' **live** values, not from the
  `content_links` edges: only a record that is `:published`, public
  (`audience: :public`) and not passphrase-locked is fired. A members-only
  update must not leak its body through a public story's artifact. The read
  runs on the fire path, which has no request actor, so it is tenant-scoped
  and filtered to exactly that rather than authorized.

  An update that is unpublished drops out the next time the story fires.
  """

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldTypes.DatetimeRange
  alias KilnCMS.CMS.ReverseFields
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing.Engine

  @default_max_updates 50

  @doc """
  How many updates a live blog fires, newest first.

      config :kiln_cms, KilnCMS.Firing.LiveBlog, max_updates: 100
  """
  @spec max_updates() :: pos_integer()
  def max_updates do
    case Application.get_env(:kiln_cms, __MODULE__, [])[:max_updates] do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_max_updates
    end
  end

  @doc """
  The `LiveBlogPosting` properties for `document`: its coverage times and
  `liveBlogUpdate` (an empty list when nothing is published yet).
  """
  @spec properties(struct()) :: map()
  def properties(document) do
    document
    |> coverage()
    |> Map.put("liveBlogUpdate", Enum.map(updates(document), &update_node/1))
  end

  @doc """
  The published, public updates of `document`, newest first and capped —
  the records behind `liveBlogUpdate`.
  """
  @spec updates(struct()) :: [struct()]
  def updates(%{id: id} = document) when is_binary(id) do
    org_id = Map.get(document, :org_id)

    case document |> Engine.public_type() |> ReverseFields.for_type(org_id) do
      [stream | _] -> read_updates(stream, id, org_id)
      [] -> []
    end
  end

  def updates(_document), do: []

  defp read_updates(stream, story_id, org_id) do
    ContentTypes.list!(stream.source_type,
      # authorize?: false — fire path, no request actor; tenant-scoped and
      # filtered to published, public, unlocked records only (moduledoc).
      authorize?: false,
      tenant: org_id,
      query: [
        filter:
          expr(
            state == :published and audience == :public and is_nil(access_password_hash) and
              ^points_at(stream.field, story_id, stream.definition.multiple)
          ),
        sort: [published_at: :desc, id: :desc],
        limit: max_updates()
      ]
    )
  end

  # Whether the live value of `field` points at `id` — jsonb containment on
  # the stored reference snapshot(s), the same test `ReverseFields` applies to
  # a working copy.
  defp points_at(field, id, true) do
    expr(
      fragment(
        "((? -> ?) @> jsonb_build_array(jsonb_build_object('id', ?::text)))",
        custom_fields,
        ^field,
        ^id
      )
    )
  end

  defp points_at(field, id, _single) do
    expr(fragment("((? -> ?) @> jsonb_build_object('id', ?::text))", custom_fields, ^field, ^id))
  end

  defp update_node(update) do
    body =
      update
      |> Map.get(:blocks)
      |> TypedBlocks.to_typed()
      |> Enum.map(&Blocks.search_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{"@type" => "BlogPosting", "headline" => Map.get(update, :title)}
    |> put_if("articleBody", body)
    |> put_if("datePublished", iso(Map.get(update, :published_at)))
    |> put_if("dateModified", iso(Map.get(update, :updated_at)))
  end

  defp coverage(document) do
    range =
      document
      |> KilnCMS.Events.schedule_value(Map.get(document, :org_id))
      |> DatetimeRange.to_utc()

    case range do
      {start_utc, end_utc} ->
        put_if(%{"coverageStartTime" => iso(start_utc)}, "coverageEndTime", iso(end_utc))

      nil ->
        put_if(%{}, "coverageStartTime", iso(Map.get(document, :published_at)))
    end
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
