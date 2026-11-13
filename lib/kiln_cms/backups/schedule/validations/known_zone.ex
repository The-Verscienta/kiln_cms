defmodule KilnCMS.Backups.Schedule.Validations.KnownZone do
  @moduledoc """
  A schedule's `time_zone` must be one the time zone database knows
  (`KilnCMS.Events.known_time_zone?/1`): refused at the form, not discovered
  by a scheduler that can't compute a window.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    zone = Ash.Changeset.get_attribute(changeset, :time_zone)

    if is_nil(zone) or KilnCMS.Events.known_time_zone?(zone),
      do: :ok,
      else: {:error, field: :time_zone, message: message()}
  end

  # Translated where the form shows it (`translate_error/1`).
  defp message, do: dgettext_noop("errors", "is not a known time zone")
end
