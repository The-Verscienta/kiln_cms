defmodule KilnCMS.CMS.Preparations.PreviewWorkingCopy do
  @moduledoc """
  Under a preview grant (#1887), returns the record it names as its
  **working copy** (`KilnCMS.CMS.WorkingCopy.view/1`) rather than the live row.

  A token is minted to show what the editor is looking at. For a never
  published draft the row already is that; for a live document with
  unpublished edits it is the copy running ahead of the row, which is what
  `GET /preview/:token` and the fired-artifact read under the same token
  render. Without this, a front end previewing such a document would read the
  published title and custom fields from JSON:API over the pending body from
  the artifact route.

  The view overlays the held text (`working_title`, `working_blocks`) and
  every held attribute (slug, custom fields, a held `category_id`, …). Held
  *to-many* links — tags, curated related content — are not overlaid here: a
  relationship load reads the live join, so `include=tags` shows the live set.

  Only on the primary read the grant applies to (`Checks.PreviewGrant`), and
  only to the named record; every other row is returned as read. The grant
  reaches a read only on a `GET`/`HEAD` (`KilnCMSWeb.Plugs.PreviewGrant`), so
  the overlaid record never feeds a write. The working-copy columns are
  selected whatever the caller's sparse fieldset, or a narrowed read would
  look as if nothing were pending.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.CMS.PreviewGrant
  alias KilnCMS.CMS.WorkingCopy

  @working_copy_fields [
    :state,
    :working_title,
    :working_blocks,
    :working_fields,
    :working_copy_at
  ]

  @impl true
  def prepare(query, _opts, _context) do
    case {PreviewGrant.from_context(query.context), query.action} do
      {%PreviewGrant{id: id}, %{type: :read, primary?: true}} ->
        query
        |> Ash.Query.ensure_selected(@working_copy_fields)
        |> Ash.Query.after_action(fn _query, records ->
          {:ok, Enum.map(records, &overlay(&1, id))}
        end)

      _ ->
        query
    end
  end

  defp overlay(%{id: id} = record, id), do: WorkingCopy.view(record)
  defp overlay(record, _id), do: record
end
