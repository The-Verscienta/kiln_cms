defmodule KilnCMS.Backups.Progress do
  @moduledoc """
  Live progress of a running backup over `Phoenix.PubSub` (#3489, part B of
  #2230): a nudge that something about a chain changed, so an open Backups
  page or Log tab re-reads the database now rather than at its next 3 s poll.

  ## A nudge, not a source

  The poll stays the source of truth and the fallback: PubSub reaches only
  the nodes clustered with the one that broadcast, and a message can be
  lost. A consumer never shows what a message says; it re-reads what it
  shows, as its poll does. So a message only has to say which chain, stamp
  or run it is about.

  ## The message

  `{:kiln_backup_progress, 1, payload}` on the instance-wide topic
  `topic/0`. `payload` is a map of exactly `keys/0`: ids, enums and counts,
  never log text, an error, a path or file name, env or destination
  config. `step` and `phase` are whitelisted to the lock's own values, and
  anything else is nil. A later version adds keys or bumps the version; a
  consumer ignores a version it doesn't know.

  ## After the commit, never inside it

  A message heard before its write commits makes a listener re-read the old
  state, and one whose transaction then rolls back announced progress that
  never happened. `broadcast/1` refuses to run inside a transaction (logged
  at debug and dropped), and the producers queue it with
  `KilnCMS.AfterCommit.run/1`:

    * `KilnCMS.Backups.Chain`'s every Lock write (`write!/3`), with
      `with_lock/1` inside `KilnCMS.AfterCommit.deferring/1`, so a lock
      transaction's messages go out once it commits and a rolled-back one
      sends nothing. The Lock writes a Run's `:cancel` makes inside its own
      transaction are dropped; `Steps.settled/2`, which the cancel calls
      after its commit, says it instead.
    * `KilnCMS.Backups.Recorder`'s Run writes that land.
    * `Steps.settled/2`, when a chain ends.

  Every Lock write goes through `write!/3`, so the releases of an
  interrupted or stranded backup (`reclaim_stale/0`, `reap/0`,
  `sweep_stranded/0`) are announced like any other. What stays poll-only:
  a Lock write made inside a transaction nobody wrapped (the cancel
  actions', which `settled/2` covers), a Run write made outside the
  `Recorder` (an import, the cancel actions' own Run write), the `Recorder`'s
  `mark_pruned/2` on other runs, and anything on a node not clustered with
  the producer.

  The current file is never sent: a path can carry personal data.
  """

  require Logger

  alias KilnCMS.Backups.Lock
  alias KilnCMS.Repo

  @topic "backups:progress"
  @version 1
  @keys [:chain, :stamp, :run, :step, :part, :phase, :percent]
  @phases [:running, :finishing]

  # The steps a fresh backup works through, in order, each an equal share of
  # the bar. `start` is not one: it always hands to `dump`, and reads as 0.
  @units [:dump, :plan, :archive, :checksum, :prune, :offsite, :finish]

  @type payload :: %{
          chain: String.t() | nil,
          stamp: String.t() | nil,
          run: String.t() | nil,
          step: atom() | nil,
          part: pos_integer() | nil,
          phase: :running | :finishing | nil,
          percent: 0..100 | nil
        }

  @doc "The topic every progress message goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The message version this node sends."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The payload's keys: every message has exactly these."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "Subscribe the calling process to `topic/0`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(KilnCMS.PubSub, @topic)

  @doc """
  The payload for a Lock write, from the row the write returned (no extra
  read). `before` is the row the write started from: a release clears the
  chain, and the message still says whose it was.
  """
  @spec lock(Lock.t(), Lock.t() | nil) :: payload()
  def lock(row, before \\ nil) do
    step = step(row.step)

    payload(%{
      chain: row.chain_id || (before && before.chain_id),
      stamp: row.stamp || row.resume_stamp || (before && (before.stamp || before.resume_stamp)),
      step: step,
      part: row.part,
      phase: row.phase,
      percent: row.chain_id && percent(step, row.part, nil)
    })
  end

  @doc "The payload for a Run write: its chain, stamp and id."
  @spec run(map()) :: payload()
  def run(%{} = run) do
    payload(%{
      chain: Map.get(run, :chain_id),
      stamp: Map.get(run, :stamp),
      run: Map.get(run, :id)
    })
  end

  @doc """
  The whitelisted payload from `fields`: only `keys/0`, each id a string,
  `step` and `phase` only as the lock has them, `part` a positive integer,
  `percent` within 0..100. Anything else is nil.
  """
  @spec payload(map()) :: payload()
  def payload(fields) when is_map(fields) do
    %{
      chain: string(fields[:chain]),
      stamp: string(fields[:stamp]),
      run: string(fields[:run]),
      step: step(fields[:step]),
      part: positive(fields[:part]),
      phase: if(fields[:phase] in @phases, do: fields[:phase]),
      percent: percent_value(fields[:percent])
    }
  end

  @doc """
  An approximate percent by steps: each of a fresh backup's steps after
  `start` an equal share, and the archive step's share split by `part` of
  `total` when both are known. A re-send (`:resend`) goes by `part` of
  `total` destinations. `start` is 0; a step outside both (nil, unknown) is
  nil. Never 100: a backup that holds the lock hasn't finished.
  """
  @spec percent(atom() | String.t() | nil, pos_integer() | nil, pos_integer() | nil) ::
          0..99 | nil
  def percent(step, part, total)

  def percent(:start, _part, _total), do: 0

  def percent(:resend, part, total) do
    case fraction(part, total) do
      nil -> nil
      fraction -> min(trunc(fraction * 100), 99)
    end
  end

  def percent(step, part, total) when is_atom(step) do
    case Enum.find_index(@units, &(&1 == step)) do
      nil ->
        nil

      index ->
        within = if step == :archive, do: fraction(part, total) || 0, else: 0
        min(trunc((index + within) / length(@units) * 100), 99)
    end
  end

  def percent(step, part, total) when is_binary(step), do: percent(step(step), part, total)

  # Done parts of `total` before `part` runs, while both make sense.
  defp fraction(part, total)
       when is_integer(part) and is_integer(total) and part >= 1 and total >= part,
       do: (part - 1) / total

  defp fraction(_part, _total), do: nil

  @doc """
  Send `payload` to `topic/0`, only outside a transaction (see the
  moduledoc). Never raises; `:ok` either way.
  """
  @spec broadcast(payload()) :: :ok
  def broadcast(%{} = payload) do
    if Repo.in_transaction?() do
      # A listener would re-read before the commit, or hear of a write
      # that rolls back. The cancel actions' own Lock writes land here.
      Logger.debug("Backup progress not broadcast: a transaction is open")
    else
      message = {:kiln_backup_progress, @version, payload(payload)}
      _ = Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, message)
    end

    :ok
  end

  @doc """
  `broadcast/1` once the enclosing transaction commits
  (`KilnCMS.AfterCommit.run/1`), or now when none is held.
  """
  @spec after_commit(payload()) :: :ok
  def after_commit(%{} = payload), do: KilnCMS.AfterCommit.run(fn -> broadcast(payload) end)

  defp step(step) when is_atom(step) and not is_nil(step) do
    if step in Lock.steps(), do: step
  end

  defp step(step) when is_binary(step), do: Enum.find(Lock.steps(), &(Atom.to_string(&1) == step))
  defp step(_step), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp percent_value(value) when is_integer(value) and value in 0..100, do: value
  defp percent_value(_value), do: nil
end
