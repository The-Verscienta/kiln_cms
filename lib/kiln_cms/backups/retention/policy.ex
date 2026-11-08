defmodule KilnCMS.Backups.Retention.Policy do
  @moduledoc """
  What `KilnCMS.Backups.Retention` keeps (#2219).

  Today one number: `keep_days`, the `BACKUP_KEEP_DAYS` every deployment
  already sets (`legacy/1`). A backup older than that may go, unless one of
  Retention's keep rules holds it. A schedule-owned policy (keep the newest N,
  a per-component minimum age) extends this struct later; `validate/1` is
  where its rules will be checked, and a policy that fails them deletes
  nothing.
  """

  @enforce_keys [:keep_days]
  defstruct [:keep_days]

  @type t :: %__MODULE__{keep_days: pos_integer()}

  @doc "The policy every deployment has today: age only, `keep_days` days."
  @spec legacy(pos_integer()) :: t()
  def legacy(keep_days), do: %__MODULE__{keep_days: keep_days}

  @doc """
  `{:ok, policy}` when `keep_days` is a positive integer, else
  `{:error, :invalid_policy}`. Anything that is not this struct is invalid.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_policy}
  def validate(%__MODULE__{keep_days: days} = policy) when is_integer(days) and days > 0,
    do: {:ok, policy}

  def validate(_other), do: {:error, :invalid_policy}
end
