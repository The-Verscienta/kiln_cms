defmodule KilnCMS.AfterCommit do
  @moduledoc """
  Holds a side effect until the transaction that caused it commits.

  An Ash `after_transaction` hook runs after the action's *own* transaction.
  When the action runs inside one it did not open — a release go-live, a
  duplicate and its links, a promotion — there is no own transaction: the hook
  runs as soon as the action returns, while the outer transaction is still open
  and can still roll back. Ash logs "One or more `after_transaction` hooks …
  ongoing transaction" for exactly that.

  Most such hooks only write — an Oban job, a ledger row — and those are right
  inside the outer transaction: they commit or vanish with it. The ones this
  module is for do something no rollback can take back, or that a reader can
  race:

    * a PubSub broadcast (calendar, collab room, task pins, GraphQL
      retraction): heard before the commit, so a listener re-reads the old
      state, and heard even when the transaction then rolls back;
    * a cache bust: a reader between the bust and the commit re-caches the old
      answer for a full TTL;
    * a write that must not be able to fail the outer transaction
      (notification dispatch, an audit anchor): a failed statement inside a
      Postgres transaction aborts the whole of it, and a rescue cannot undo
      that.

  A hook wraps such an effect in `run/1`. Outside any `deferring/1` block that
  runs it at once — the normal case, where the hook already runs after COMMIT.
  Inside one, it is queued, and `deferring/1` runs the queue when the block
  returns `{:ok, _}` and drops it otherwise.

  The caller that opens the outer transaction wraps it in `deferring/1`, and
  only then may it pass `context/0` to the actions it runs, silencing Ash's
  warning for them: the silence is a claim that every hook those actions reach
  either writes inside the transaction on purpose or goes through `run/1`.

  `capture/1` is for a hook that runs another action inside its own action's
  transaction (`Changes.AutoCompleteTasks`): it collects what that action
  deferred so the outer action can `replay/1` it from its own
  `after_transaction` hook.

  The queue lives in the process dictionary. `Repo.transaction/2` and Ash's
  hooks run in the calling process, which is what makes that sound.
  """

  require Logger

  alias KilnCMS.Repo

  @key {__MODULE__, :queue}

  @typedoc "A queued side effect."
  @type callback :: (-> any())

  @doc """
  Run `fun`, which opens a transaction, and hold every `run/1` effect inside it
  until it returns `{:ok, _}`. Any other return drops them.

  Inside another `deferring/1` the effects join the outer queue, since only the
  outermost transaction really commits. Inside a transaction nobody wrapped,
  nothing is held — there is no commit here to wait for, so the effects run at
  once, as they would without this.
  """
  @spec deferring((-> result)) :: result when result: term()
  def deferring(fun) when is_function(fun, 0) do
    cond do
      Process.get(@key) -> fun.()
      Repo.in_transaction?() -> fun.()
      true -> hold(fun)
    end
  end

  defp hold(fun) do
    Process.put(@key, [])

    {result, queued} =
      try do
        result = fun.()
        {result, Process.get(@key, [])}
      after
        Process.delete(@key)
      end

    case result do
      {:ok, _} -> replay(queued)
      _rolled_back -> :ok
    end

    result
  end

  @doc """
  Run `fun` now, or after the enclosing `deferring/1` block commits.
  Returns `:ok`.
  """
  @spec run(callback()) :: :ok
  def run(fun) when is_function(fun, 0) do
    case Process.get(@key) do
      nil -> safely(fun)
      queue -> Process.put(@key, [fun | queue])
    end

    :ok
  end

  @doc """
  Run `fun` and return `{result, effects}`: the `run/1` effects it would have
  run or queued, held back for the caller to `replay/1`. Effects already queued
  before the call are untouched.
  """
  @spec capture((-> result)) :: {result, [callback()]} when result: term()
  def capture(fun) when is_function(fun, 0) do
    outer = Process.get(@key)
    Process.put(@key, [])

    try do
      result = fun.()
      {result, Process.get(@key, [])}
    after
      if outer, do: Process.put(@key, outer), else: Process.delete(@key)
    end
  end

  @doc """
  Hand effects `capture/1` collected back to `run/1`, oldest first — run now,
  or queued again behind an enclosing `deferring/1`.
  """
  @spec replay([callback()]) :: :ok
  def replay(queued) when is_list(queued) do
    queued |> Enum.reverse() |> Enum.each(&run/1)
  end

  @doc """
  The action context that silences Ash's nested-`after_transaction` warning.
  Only for an action run inside `deferring/1` — see the module doc.
  """
  @spec context() :: map()
  def context, do: %{warn_on_transaction_hooks?: false}

  # The write these report on has committed by the time a queued effect runs,
  # so one that raises must not reach the caller as a failure of that write,
  # nor stop the effects behind it. An effect run at once (no enclosing block)
  # is in the same position: it is an `after_transaction` hook's body.
  defp safely(fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "after-commit effect failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  end
end
