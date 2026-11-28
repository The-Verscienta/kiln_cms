defmodule KilnCMS.Security.Changes.NoticePlatformAlertSettings do
  @moduledoc """
  The platform notice (#2811) of a `KilnCMS.Security.PlatformAlertSettings`
  save that turns a platform alert kind off: `platform_kind_disabled`, naming
  the kinds newly turned off and who turned them off. It goes to every
  platform admin, the one who saved included, by email and in the default
  org's bell (`KilnCMS.Security.Changes.DeliverAlert`). Turning a kind back
  on, or saving it unchanged, raises nothing.

  The row as it was is read **before** the write, locked (`FOR UPDATE`), as
  `KilnCMS.Security.alerts_system/0` with `authorize_with: :error`: two saves
  are compared one after the other, and a read that is refused fails the save
  rather than compare against nothing. With no row yet there is nothing to
  lock, so two concurrent first saves may both send a notice: the safe
  direction.

  The notice is written in the save's transaction
  (`KilnCMS.Security.AlertGate.insert_platform_notice!/1`) and fails closed: a
  notice that cannot be written fails the save with `{:error, _}` and rolls
  it back, its instance security log event with it.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Accounts.User
  alias KilnCMS.Security
  alias KilnCMS.Security.AlertGate

  @before_key :platform_alert_settings_before

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.set_context(changeset, %{@before_key => current()})
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      before = Map.fetch!(changeset.context, @before_key)

      case newly_disabled(before, record.disabled_kinds) do
        [] -> {:ok, Ash.Resource.put_metadata(record, :platform_notice?, false)}
        kinds -> notice(record, kinds, actor_id(changeset))
      end
    end)
  end

  # A database error writing the notice is returned rather than raised: the
  # save fails and rolls back all the same, and its caller (the settings page)
  # gets `{:error, _}` to say so instead of a crash. Anything else raises.
  defp notice(record, kinds, actor_id) do
    AlertGate.insert_platform_notice!(%{
      change: "platform_kind_disabled",
      kinds: kinds,
      actor_id: actor_id
    })

    # The page says a notice is on its way only when this save wrote one,
    # judged from the locked row, never from what the page last loaded.
    {:ok, Ash.Resource.put_metadata(record, :platform_notice?, true)}
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error(
        "Platform alert settings not saved: the platform notice could not be written: " <>
          Exception.message(error)
      )

      {:error, error}
  end

  defp current do
    query = Ash.Query.lock(Security.PlatformAlertSettings, :for_update)

    case Security.list_platform_alert_settings!(
           query: query,
           actor: Security.alerts_system(),
           authorize_with: :error
         ) do
      [row | _] -> row.disabled_kinds || []
      [] -> []
    end
  end

  @doc false
  # The kinds a save from `before` to `after_write` newly turns off, sorted.
  @spec newly_disabled([String.t()], [String.t()] | nil) :: [String.t()]
  def newly_disabled(before, after_write) do
    # `uniq` first: `--` removes one occurrence per element, so a kind listed
    # twice would otherwise read as newly turned off.
    after_write = Enum.uniq(after_write || [])
    Enum.sort(after_write -- before)
  end

  defp actor_id(changeset) do
    case changeset.context[:private][:actor] do
      %User{id: id} -> id
      _other -> nil
    end
  end
end
