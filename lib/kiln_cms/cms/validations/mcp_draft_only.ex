defmodule KilnCMS.CMS.Validations.McpDraftOnly do
  @moduledoc """
  Refuses `:update` of a **published** record when the call came through
  `/mcp` (`kiln_surface: :mcp`, set by `KilnCMSWeb.Plugs.McpSurface`).

  `:update` writes the live row and re-fires a published record's artifacts,
  so over MCP it would put an LLM's edit in front of readers with nobody
  reviewing it. MCP authoring is draft-only (docs/mcp.md): a live record is
  edited through `save_*_working_copy` instead, which holds the change until a
  person clicks *Publish changes* (docs/working-copy.md).

  Only MCP. JSON:API `PATCH`, GraphQL and in-context editing still edit a live
  record directly, on purpose (docs/working-copy.md, "Not in this change").

  The state is read from `changeset.data`, the row as it was read: an
  `:update` never changes `state`, so that is also the state it writes.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @impl true
  def validate(changeset, _opts, _context) do
    if mcp?(changeset) and Map.get(changeset.data, :state) == :published do
      {:error,
       InvalidChanges.exception(
         message:
           "this record is published, and MCP edits never go live directly; " <>
             "use the save_*_working_copy tool to stage the change for a person to publish"
       )}
    else
      :ok
    end
  end

  defp mcp?(%{context: %{kiln_surface: :mcp}}), do: true
  defp mcp?(_changeset), do: false
end
