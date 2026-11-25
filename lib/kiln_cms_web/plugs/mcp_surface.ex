defmodule KilnCMSWeb.Plugs.McpSurface do
  @moduledoc """
  Marks a `/mcp` request in the Ash context (`kiln_surface: :mcp`), so an
  action can tell a tool call from the same action reached through JSON:API,
  GraphQL or the editor.

  `AshAi.Mcp.Router` runs each tool with `Ash.PlugHelpers.get_context/1`, so
  the mark reaches the changeset as `changeset.context.kiln_surface`. It is
  read by `KilnCMS.CMS.Validations.McpDraftOnly`, which keeps `update_*` off
  live records (docs/mcp.md, "Live records").

  The key is top-level context, not `shared`: a change that builds its own
  changeset (the working copy's `:update` probe in
  `KilnCMS.CMS.Changes.StageWorkingFields`) does not carry it, which is what
  lets `save_*_working_copy` validate its held fields through `:update`.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    context = Ash.PlugHelpers.get_context(conn) || %{}
    Ash.PlugHelpers.set_context(conn, Map.put(context, :kiln_surface, :mcp))
  end
end
