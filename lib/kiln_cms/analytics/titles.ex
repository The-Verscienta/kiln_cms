defmodule KilnCMS.Analytics.Titles do
  @moduledoc """
  Id-batched title resolution for analytics rows, shared by `AnalyticsLive`
  and the analytics export (#618) so both apply the same `"(deleted)"` /
  `"(unknown type: ...)"` fallbacks, and so a spreadsheet of exported view
  buckets is legible rather than a list of UUIDs.

  Runs under the caller's own `actor` — never `authorize?: false` — so a
  title lookup never surfaces content that actor couldn't otherwise read
  (design doc, #618 Export: "policy-gated CMS reads on the export path").
  """

  alias KilnCMS.CMS.ContentTypes

  @doc """
  Resolves `%{content_id => {title, slug}}` for a list of rows that each have
  `:content_type` and `:content_id`, batching the lookup into one policy-gated
  read per content type (deduped ids) instead of one per row.

  Content whose type is no longer registered is omitted entirely; content
  whose id no longer exists (deleted, or simply unreadable by `actor`) is
  absent from the map. Use `title_for/3` for the fallback both existing
  callers apply.
  """
  @spec resolve([%{content_type: String.t(), content_id: Ash.UUID.t()}], term(), term()) ::
          %{Ash.UUID.t() => {String.t(), String.t() | nil}}
  def resolve(rows, org, actor) do
    rows
    |> Enum.group_by(& &1.content_type)
    |> Enum.flat_map(fn {type, type_rows} ->
      case ContentTypes.get(type, org_id(org)) do
        nil -> []
        ct -> batch_lookup(ct, type_rows |> Enum.map(& &1.content_id) |> Enum.uniq(), org, actor)
      end
    end)
    |> Map.new()
  end

  @doc """
  The display title for one row: `"(unknown type: ...)"` when the content
  type itself is no longer registered (mirrors `AnalyticsLive`'s own
  distinction), `"(deleted)"` when the type is fine but this id is absent
  from `titles` (deleted, or unreadable by the actor `resolve/3` was called
  with), or the resolved title otherwise.
  """
  @spec title_for(%{content_type: String.t(), content_id: Ash.UUID.t()}, map(), term()) ::
          String.t()
  def title_for(row, titles, org) do
    case ContentTypes.get(row.content_type, org_id(org)) do
      nil -> "(unknown type: #{row.content_type})"
      _ct -> titles |> Map.get(row.content_id, {"(deleted)", nil}) |> elem(0)
    end
  end

  # The title-resolution read is tenant-strict (#419) — scope to the caller's
  # org — and policy-gated under `actor` (#618): no `authorize?: false`, so a
  # title never leaks content the requesting actor couldn't otherwise read.
  defp batch_lookup(ct, ids, org, actor) do
    ct.type
    |> ContentTypes.list!(
      actor: actor,
      tenant: org,
      query: [filter: [id: [in: ids]], select: [:id, :title, :slug]]
    )
    |> Enum.map(&{&1.id, {&1.title, &1.slug}})
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id), do: id
end
