defmodule KilnCMS.Backups.Schedule.Validations.MediaAvailable do
  @moduledoc """
  A schedule may name `:media` only on a deployment with a media directory to
  archive (`KilnCMS.Backups.media_dir/0`). Checked when the components are
  set or changed, so a media schedule whose directory went away can still be
  paused, resumed or deleted (each of its windows is then refused, or narrowed
  to the database, by `KilnCMS.Backups.request_scheduled/3`).
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    components = Ash.Changeset.get_attribute(changeset, :components) || []

    if Ash.Changeset.changing_attribute?(changeset, :components) and :media in components and
         is_nil(KilnCMS.Backups.media_dir()),
       do: {:error, field: :components, message: message()},
       else: :ok
  end

  # Translated where the form shows it (`translate_error/1`).
  defp message, do: dgettext_noop("errors", "media isn't archived on this deployment")
end
