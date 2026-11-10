defmodule KilnCMS.Security.Posture.Runner do
  @moduledoc """
  Runs posture checks (#2252), each in its own process under its own
  deadline, all at once, so the page waits at most as long as the slowest
  check's deadline.

  ## A check cannot take the page down, or turn it green

  Every check runs in a task under `KilnCMS.Security.Posture.TaskSupervisor`
  (its own, so a page full of slow plugin checks cannot starve the tasks the
  rest of the app starts, and capped at #{50} at once). A check that raises,
  throws or exits is an `:error` entry with `error: :crashed`; one that answers
  anything but a `Kiln.Security.Check.Result` (or one the sanitizer cannot
  read) is `:invalid_result`; one still
  running at its deadline is killed and is `:timeout`; one for which no task
  could be started (the supervisor is full) is `:busy`. The exception is
  logged here, never put on the page.

  ## The deadline holds without the caller

  Each task arms `:timer.kill_after/1` for its own deadline before it calls
  the check, so it dies on time even if the process that started it (the
  LiveView's async task, say) is gone and nobody is left to shut it down.
  Work a check hands to another process is not covered: it is not this
  task's to kill.

  ## Telemetry

  `[:kiln_cms, :security_posture, :check, :stop]` for every check, with
  `%{duration: native}` and `%{id:, status:, error:}`; and
  `[:kiln_cms, :security_posture, :check, :exception]` as well for a check
  that crashed, with `%{id:, kind:}`.
  """

  require Logger

  alias Kiln.Security.Check.Context
  alias Kiln.Security.Check.Result
  alias KilnCMS.Security.Posture.Entry

  @supervisor KilnCMS.Security.Posture.TaskSupervisor

  @doc "The task supervisor checks run under."
  @spec supervisor() :: atom()
  def supervisor, do: @supervisor

  @doc """
  Run every descriptor (`KilnCMS.Security.Posture.Registry.checks/0`) with the
  context `context_for.(scope)` builds, and answer one entry per descriptor,
  in the same order.
  """
  @spec run([map()], (:site | :deployment -> Context.t())) :: [Entry.t()]
  def run(descriptors, context_for) when is_function(context_for, 1) do
    started = System.monotonic_time(:millisecond)

    descriptors
    |> Enum.map(fn descriptor ->
      {descriptor, start(descriptor, context_for.(descriptor.scope))}
    end)
    |> Enum.map(fn {descriptor, started_task} -> collect(descriptor, started_task, started) end)
  end

  defp start(descriptor, context) do
    {:ok, Task.Supervisor.async_nolink(@supervisor, fn -> run_check(descriptor, context) end)}
  rescue
    # `async_nolink/2` raises (rather than answering an error) when the
    # supervisor is at `max_children`. That is the one thing that can go wrong
    # here, and it means "no room right now", not a bug.
    RuntimeError -> :busy
  end

  # Runs in the task. The kill timer comes first, so nothing the check does
  # can outlive its deadline; the locale comes next, so a check's own gettext
  # calls answer in the reader's language.
  defp run_check(descriptor, %Context{} = context) do
    {:ok, _timer} = :timer.kill_after(descriptor.timeout)
    Gettext.put_locale(KilnCMSWeb.Gettext, context.locale)
    started = System.monotonic_time()

    outcome =
      try do
        {:returned, descriptor.module.run(context)}
      rescue
        # A boundary: the check is third-party code, and its failure is a row
        # on the page, not a crash of the report. Logged, never shown.
        error ->
          log_crash(descriptor, :error, Exception.format(:error, error, __STACKTRACE__))
          {:crashed, :error}
      catch
        kind, reason ->
          log_crash(descriptor, kind, Exception.format(kind, reason, __STACKTRACE__))
          {:crashed, kind}
      end

    {outcome, System.monotonic_time() - started}
  end

  defp log_crash(descriptor, kind, formatted) do
    Logger.error(
      "Security posture check #{descriptor.id} (#{inspect(descriptor.module)}) failed with #{kind}:\n" <>
        formatted
    )
  end

  defp collect(descriptor, :busy, _started), do: entry(descriptor, :error, :busy, nil, 0)

  defp collect(descriptor, {:ok, task}, started) do
    remaining = max(descriptor.timeout - (System.monotonic_time(:millisecond) - started), 0)

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, {{:returned, result}, duration}} ->
        case sanitize(descriptor, result) do
          {:ok, clean} -> entry(descriptor, clean.status, nil, clean, duration)
          :error -> entry(descriptor, :error, :invalid_result, nil, duration)
        end

      {:ok, {{:crashed, kind}, duration}} ->
        :telemetry.execute(
          [:kiln_cms, :security_posture, :check, :exception],
          %{duration: duration},
          %{id: descriptor.id, kind: kind}
        )

        entry(descriptor, :error, :crashed, nil, duration)

      # Killed by its own timer between `yield` and `shutdown`, or by anything
      # else from outside: either way it produced nothing.
      {:exit, :killed} ->
        entry(descriptor, :error, :timeout, nil, ms_to_native(descriptor.timeout))

      {:exit, _reason} ->
        entry(descriptor, :error, :crashed, nil, 0)

      nil ->
        entry(descriptor, :error, :timeout, nil, ms_to_native(descriptor.timeout))
    end
  end

  # A boundary like `run_check/2`'s: the result is third-party data, and one
  # that makes the sanitizer raise is an `:invalid_result` row, not a crash of
  # the whole report. Logged, never shown.
  defp sanitize(descriptor, result) do
    Result.sanitize(result)
  rescue
    error ->
      Logger.error(
        "Security posture check #{descriptor.id} (#{inspect(descriptor.module)}) answered a " <>
          "result that could not be sanitized:\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end

  defp entry(descriptor, status, error, result, duration) do
    :telemetry.execute(
      [:kiln_cms, :security_posture, :check, :stop],
      %{duration: duration},
      %{id: descriptor.id, status: status, error: error}
    )

    %Entry{
      id: descriptor.id,
      title: descriptor.title,
      description: descriptor.description,
      scope: descriptor.scope,
      source: descriptor.source,
      status: status,
      error: error,
      result: result,
      duration_ms: System.convert_time_unit(duration, :native, :millisecond)
    }
  end

  defp ms_to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
end
