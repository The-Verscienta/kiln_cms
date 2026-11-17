defmodule KilnCMS.Jobs.PrivateArgs do
  @moduledoc """
  Job arguments that must not outlive their job (#2992).

  A job's `args` are written to `oban_jobs`, printed by Oban's logger on every
  start and stop, and attached to the `extra` of any Sentry event the job
  raises. The Pruner deletes the row after a week. For most jobs that is
  harmless: the args are ids. For a few it is not, because the args carry what
  a visitor or an editor wrote:

    * `KilnCMS.Forms.NotificationWorker` and `KilnCMS.Forms.AutoresponderWorker`
      carried the submitted form `data` (and the autoresponder its `to`
      address). They now carry the submission's id and read the submission
      back when they run; `data` and `to` are only in jobs queued by an earlier
      release.
    * `KilnCMS.Automation.DispatchWorker` and `KilnCMS.Automation.RuleWorker`
      carry the event's `payload`, the serialized document (drafts included),
      as it was when the event fired. A rule's reaction needs that snapshot, so
      it cannot be read back by id. Readers accept it either in the clear
      (`"payload"`) or sealed (`"sealed"`, `seal/1`), so a later release can
      switch the writers to the sealed form while a rolling deploy runs both.

  Whichever shape a job carries, the keys `registry/0` names are dropped from
  its row once the job is finished (`finishing/3`), and
  `KilnCMS.Jobs.PrivateArgsScrub` drops them from finished rows that still hold
  them. `KilnCMS.SentryFilter` drops them from a Sentry event's `extra.args`,
  and drops the stack frames' variables, for a job of a registered worker.

  `KilnCMS.Mail` keeps its own mail-message keys (`KilnCMS.Mail.forget_body/1`,
  `KilnCMS.Mail.Scrub`); this module covers the jobs that are not mail.
  """
  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.Keys.Vault

  # Worker name, as Oban stores it in `oban_jobs.worker` and Sentry's Oban
  # integration puts it in `extra.worker` (no `Elixir.` prefix), to the arg
  # keys that hold private data. Strings rather than modules so a lookup by
  # the stored name never has to create an atom.
  @registry %{
    "KilnCMS.Forms.NotificationWorker" => ~w(data),
    "KilnCMS.Forms.AutoresponderWorker" => ~w(data to),
    "KilnCMS.Automation.DispatchWorker" => ~w(payload sealed),
    "KilnCMS.Automation.RuleWorker" => ~w(payload sealed)
  }

  @doc "Every registered worker name and the arg keys `forget/2` drops from its jobs."
  @spec registry() :: %{String.t() => [String.t()]}
  def registry, do: @registry

  @doc """
  The private arg keys of `worker` (a module or the name Oban stores), `[]`
  for a worker that is not registered.
  """
  @spec keys(module() | String.t() | nil) :: [String.t()]
  def keys(nil), do: []
  def keys(worker), do: Map.get(@registry, Oban.Worker.to_string(worker), [])

  @doc "Whether `worker` (a module or the name Oban stores) has private args."
  @spec registered?(module() | String.t() | nil) :: boolean()
  def registered?(worker), do: keys(worker) != []

  @doc """
  Encrypt `value` (anything `Jason` encodes) for a job's args, with
  `KilnCMS.Keys.Vault`, as base64 so it survives the JSON column.
  """
  @spec seal(term()) :: String.t()
  def seal(value), do: value |> Jason.encode!() |> Vault.encrypt() |> Base.encode64()

  @doc """
  Decrypt what `seal/1` wrote. `{:error, :unreadable}` when it does not open
  under any `secret_key_base` this deployment knows (rotated without
  `PREVIOUS_SECRET_KEY_BASE`), or is not something `seal/1` wrote.
  """
  @spec open(term()) :: {:ok, term()} | {:error, :unreadable}
  def open(sealed) when is_binary(sealed) do
    with {:ok, ciphertext} <- Base.decode64(sealed),
         {:ok, json} <- Vault.decrypt(ciphertext),
         {:ok, value} <- Jason.decode(json) do
      {:ok, value}
    else
      _unreadable -> {:error, :unreadable}
    end
  end

  def open(_sealed), do: {:error, :unreadable}

  @doc "The cancel reason for a job whose sealed args `open/1` refused."
  @spec describe_unreadable() :: String.t()
  def describe_unreadable,
    do:
      "job arguments could not be opened: they were sealed under a SECRET_KEY_BASE " <>
        "this deployment no longer has (set PREVIOUS_SECRET_KEY_BASE)"

  @doc """
  Drop `keys` from the stored row of `job`.

  Best-effort: a failure is logged and swallowed, because the job's work is
  already done and a raise would make Oban run it again. A job that was never
  inserted (`id: nil`, as in `Oban.Testing.perform_job/3`) is left alone.
  """
  @spec forget(Oban.Job.t(), [String.t()]) :: :ok
  def forget(%Oban.Job{id: nil}, _keys), do: :ok
  def forget(%Oban.Job{}, []), do: :ok

  def forget(%Oban.Job{id: id, worker: worker}, keys) do
    from(j in Oban.Job,
      where: j.id == ^id,
      update: [set: [args: fragment("? - ?::text[]", j.args, ^keys)]]
    )
    |> KilnCMS.Repo.update_all([])

    :ok
  rescue
    error ->
      Logger.warning(
        "Could not drop the private arguments of #{worker} job #{id}: " <>
          inspect(error.__struct__)
      )

      :ok
  end

  @doc """
  Run `fun` as `job`'s work and drop `keys` from the job's row once its
  outcome finishes the job, then return the outcome (or re-raise).

  Finished: `:ok`, `{:ok, _}`, `:discard`, `{:discard, _}` and `{:cancel, _}`,
  any other value Oban counts as success, and `{:error, _}` or a raise, exit
  or throw on the job's last attempt (Oban discards it after that). Kept:
  `{:snooze, _}` and a failure with attempts left, because the job runs again
  and needs its args.
  """
  @spec finishing(Oban.Job.t(), [String.t()], (-> result)) :: result when result: term()
  def finishing(%Oban.Job{} = job, keys, fun) when is_function(fun, 0) do
    outcome = fun.()
    if finished?(job, outcome), do: forget(job, keys)
    outcome
  catch
    kind, reason ->
      if last_attempt?(job), do: forget(job, keys)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp finished?(_job, {:snooze, _period}), do: false
  defp finished?(job, {:error, _reason}), do: last_attempt?(job)
  defp finished?(_job, _outcome), do: true

  defp last_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
