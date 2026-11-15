defmodule KilnCMS.Backups.Retention.Policy do
  @moduledoc """
  What `KilnCMS.Backups.Retention` keeps (#2219).

  `keep_days` is the `BACKUP_KEEP_DAYS` every deployment sets: a backup older
  than that may go, unless one of Retention's keep rules holds it.
  `schedules` are the in-app schedules' keep rules (`current/0`), one per
  `KilnCMS.Backups.Schedule`, paused ones included:

    * `id` - the schedule's id, matched against a Run's `schedule_ids`.
    * `kinds` - the components it backs up (`:db`, `:media`); a component a
      newer release wrote (`KilnCMS.Types.UnknownAtom`) is dropped.
    * `keep_count` - keep the newest N backups of each of those kinds, or
      `nil`.
    * `keep_days` - the age its own backups are kept to: the schedule's
      `keep_days`, or `BACKUP_KEEP_DAYS` when it has none. May be below
      `BACKUP_KEEP_DAYS`.

  `legacy/1` is a policy with no schedules: age only, exactly what retention
  did before schedules could keep anything. A policy that fails `validate/1`
  deletes nothing.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Schedule

  @enforce_keys [:keep_days]
  defstruct keep_days: nil, schedules: []

  @type rule :: %{
          id: String.t(),
          kinds: [:db | :media],
          keep_count: pos_integer() | nil,
          keep_days: pos_integer()
        }

  @type t :: %__MODULE__{keep_days: pos_integer(), schedules: [rule()]}

  @doc "Age only, `keep_days` days, and no schedule's keep rules."
  @spec legacy(pos_integer()) :: t()
  def legacy(keep_days), do: %__MODULE__{keep_days: keep_days, schedules: []}

  @doc """
  The policy in force: `BACKUP_KEEP_DAYS` and every schedule's keep rules.
  Schedules are read as the `:backups` system actor with
  `authorize_with: :error`, so a refused or failed read is
  `{:error, {:read_schedules, error_module}}`, never "no schedules": a policy
  missing a schedule's keep count would delete what it keeps.
  """
  @spec current() :: {:ok, t()} | {:error, {:read_schedules, module()}}
  def current do
    case Backups.list_backup_schedules(actor: Backups.system(), authorize_with: :error) do
      {:ok, schedules} -> {:ok, from_schedules(Backups.keep_days(), schedules)}
      {:error, error} -> {:error, {:read_schedules, error.__struct__}}
    end
  end

  @doc """
  The policy for `keep_days` and these schedules. Pure; `current/0` is this
  over the stored rows.
  """
  @spec from_schedules(pos_integer(), [Schedule.t() | map()]) :: t()
  def from_schedules(keep_days, schedules) do
    %__MODULE__{
      keep_days: keep_days,
      schedules: Enum.map(schedules, &rule(&1, keep_days))
    }
  end

  defp rule(schedule, keep_days) do
    %{
      id: schedule.id,
      kinds: Enum.filter(schedule.components || [], &(&1 in [:db, :media])),
      keep_count: schedule.keep_count,
      keep_days: schedule.keep_days || keep_days
    }
  end

  @doc """
  `{:ok, policy}` when `keep_days` is a positive integer and every schedule
  rule has an id, a list of kinds, a positive `keep_days` and a positive or
  `nil` `keep_count`; else `{:error, :invalid_policy}`. Only positivity is
  checked: the maxima are the schedule's own constraints. Anything that is
  not this struct is invalid.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_policy}
  def validate(%__MODULE__{keep_days: days, schedules: rules} = policy)
      when is_integer(days) and days > 0 and is_list(rules) do
    if Enum.all?(rules, &valid_rule?/1), do: {:ok, policy}, else: {:error, :invalid_policy}
  end

  def validate(_other), do: {:error, :invalid_policy}

  defp valid_rule?(%{id: id, kinds: kinds, keep_count: count, keep_days: days})
       when is_binary(id) and is_list(kinds) and is_integer(days) and days > 0 do
    Enum.all?(kinds, &(&1 in [:db, :media])) and
      (is_nil(count) or (is_integer(count) and count > 0))
  end

  defp valid_rule?(_other), do: false
end
