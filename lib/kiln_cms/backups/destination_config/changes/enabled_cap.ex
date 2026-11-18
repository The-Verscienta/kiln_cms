defmodule KilnCMS.Backups.DestinationConfig.Changes.EnabledCap do
  @moduledoc """
  At most `KilnCMS.Backups.DestinationConfig.max_enabled/0` destinations are
  enabled (decision E8), held under concurrency (#2952).

  `Validations.AdapterSettings` counts the enabled destinations when a save
  enables one, but a validation runs before the action's transaction: two
  saves enabling the last free place at once could both count seven. So a
  save that enables a destination counts again here, in a `before_action`,
  inside the transaction, after taking a transaction-scoped advisory lock on
  one fixed key. The second of two such saves waits for the first to commit
  or roll back, then counts what it wrote.

  Only enabling takes the lock: a disable, a rename or a reorder can't put
  the count over the cap.
  """
  use Ash.Resource.Change
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Backups
  alias KilnCMS.Backups.DestinationConfig

  @lock_key "kiln:backup_destinations:enabled_cap"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if enabling?(changeset), do: locked_check(changeset), else: changeset
    end)
  end

  defp locked_check(changeset) do
    KilnCMS.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@lock_key])

    case check(changeset) do
      :ok -> changeset
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  @doc """
  Whether `changeset` enables its destination: a create that is enabled, or
  an update of a disabled one to enabled.
  """
  @spec enabling?(Ash.Changeset.t()) :: boolean()
  def enabling?(changeset) do
    Ash.Changeset.get_attribute(changeset, :enabled) == true and
      (changeset.action_type == :create or changeset.data.enabled != true)
  end

  @doc """
  `:ok` when `changeset` doesn't enable its destination or there is room for
  one more, else the refusal. The other rows are read as the `:backups`
  system actor with `authorize_with: :error`, so a refused or failed read
  refuses the save rather than passing the cap on an empty list.
  """
  @spec check(Ash.Changeset.t()) :: :ok | {:error, Exception.t()}
  def check(changeset) do
    if enabling?(changeset) do
      case Backups.list_enabled_backup_destinations(
             actor: Backups.system(),
             authorize_with: :error
           ) do
        {:ok, enabled} -> room(Enum.reject(enabled, &(&1.id == changeset.data.id)))
        {:error, _error} -> {:error, unreadable()}
      end
    else
      :ok
    end
  end

  defp room(others) do
    if length(others) < DestinationConfig.max_enabled(),
      do: :ok,
      else:
        {:error,
         InvalidAttribute.exception(
           field: :enabled,
           message: dgettext_noop("errors", "at most %{max} destinations can be enabled"),
           vars: [max: DestinationConfig.max_enabled()]
         )}
  end

  defp unreadable do
    InvalidAttribute.exception(
      field: :settings,
      message:
        dgettext_noop("errors", "the other backup destinations couldn't be read; try again"),
      vars: []
    )
  end
end
