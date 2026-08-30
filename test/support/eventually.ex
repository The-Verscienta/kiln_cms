defmodule KilnCMS.Test.Eventually do
  @moduledoc """
  Deadline-based polling for eventually-consistent test state (#1349).

  `ConnCase.eventually/4`'s docstring carries the post-mortem this module
  generalizes: a `tries \\\\ N` × `sleep(25)` budget is one second on a
  developer's machine and a flake on a loaded CI runner, and shortening the
  poll interval later silently shrinks the budget. A *deadline* has neither
  problem, and a generous one costs nothing when the condition holds — the
  loop returns on the first truthy check.

  Four files carried hand-rolled copies of the tries-count shape
  (`collab_saved_refresh_test`, `collab_persister_test`,
  `crdt_materialization_test`, `collab_test`), and one carried a poller that
  returned `:ok` on exhaustion and so could never fail on its own
  (`content_editor_block_presence_test`). All five now delegate here.

  `ConnCase.eventually/4` stays the ergonomic form for "this substring
  (dis)appears in a LiveView render"; it is built on this module. Reach for
  `eventually/2` directly for any other eventually-consistent condition —
  never for a fixed `Process.sleep`.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @poll_ms 25
  @default_timeout_ms 5_000

  @doc """
  Poll `check` until it returns a truthy value, and return that value.

  Flunks when `timeout_ms` (default #{@default_timeout_ms}) elapses first.

  Options:

    * `:timeout_ms` — the deadline, in wall-clock milliseconds.
    * `:message` — what the flunk says: a string, or a zero-arity fun run at
      flunk time, so it can capture the state that never settled (a last
      render, a lock holder) without paying for it on the passing path.
  """
  @spec eventually((-> term()), keyword()) :: term()
  def eventually(check, opts \\ []) when is_function(check, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    message = Keyword.get(opts, :message)
    poll(check, message, System.monotonic_time(:millisecond) + timeout_ms, timeout_ms)
  end

  defp poll(check, message, deadline, timeout_ms) do
    case check.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(flunk_message(message, timeout_ms))
        else
          Process.sleep(@poll_ms)
          poll(check, message, deadline, timeout_ms)
        end

      truthy ->
        truthy
    end
  end

  defp flunk_message(nil, timeout_ms),
    do: "the polled condition never held within #{timeout_ms}ms"

  defp flunk_message(message, timeout_ms) when is_binary(message),
    do: "#{message} (within #{timeout_ms}ms)"

  defp flunk_message(message, _timeout_ms) when is_function(message, 0), do: message.()
end
