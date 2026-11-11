defmodule KilnCMSWeb.ContentTrash do
  @moduledoc """
  "Move to trash" on a single document (#2137), shared by the content list's
  row menu (`KilnCMSWeb.EditorLive`) and the content editor's Settings tab
  (`KilnCMSWeb.ContentEditorLive`), so the two surfaces say the same thing
  and run the same write.

  The write is the type's soft delete (`ContentTypes.destroy/3`, AshArchival):
  the record leaves every read and the live site, and an admin can restore it
  from Trash until the nightly purge removes it. Who may do it is the content
  policy's call; callers check `ContentTypes.can_destroy?/4` both to draw the
  control and again in the event handler.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.CMS.ContentTypes

  @retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  @doc "How many days an admin can restore a trashed document for."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  Move `record` (of content type `kind`) to the trash as `actor` on `org`.
  The policy decides; a refusal comes back as `{:error, %Ash.Error.Forbidden{}}`.
  """
  @spec trash(term(), Ash.Resource.Record.t(), term(), term()) :: :ok | {:error, term()}
  def trash(kind, record, actor, org),
    do: ContentTypes.destroy(kind, record, actor: actor, tenant: org)

  @doc """
  The confirm prompt for trashing `record`: what happens, and for how long it
  can be undone. A published record also comes off the live site, and
  restoring it puts it straight back.
  """
  @spec confirm(Ash.Resource.Record.t()) :: String.t()
  def confirm(%{state: :published} = record) do
    gettext(
      "Move “%{title}” to trash? It comes off the live site now. Admins can restore it from Trash for %{days} days, which puts it back on the site.",
      title: title(record),
      days: @retention_days
    )
  end

  def confirm(record) do
    gettext("Move “%{title}” to trash? Admins can restore it from Trash for %{days} days.",
      title: title(record),
      days: @retention_days
    )
  end

  @doc """
  The Settings tab's explanation of the control, for a record in `state`.
  """
  @spec explanation(Ash.Resource.Record.t()) :: String.t()
  def explanation(%{state: :published}) do
    gettext(
      "Moving this to trash takes it off the live site and out of the content list. Admins can restore it from Trash for %{days} days.",
      days: @retention_days
    )
  end

  def explanation(_record) do
    gettext(
      "Moving this to trash removes it from the content list. Admins can restore it from Trash for %{days} days.",
      days: @retention_days
    )
  end

  @doc "The flash after `record` was moved to the trash."
  @spec moved(Ash.Resource.Record.t()) :: String.t()
  def moved(record), do: gettext("Moved “%{title}” to trash.", title: title(record))

  @doc "The flash when the record to trash could not be found."
  @spec not_found() :: String.t()
  def not_found, do: gettext("Couldn't move that to trash. It may already be gone.")

  defp title(%{title: title}) when is_binary(title) and title != "", do: title
  defp title(_record), do: gettext("Untitled")
end
