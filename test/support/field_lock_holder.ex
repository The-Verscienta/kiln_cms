defmodule KilnCMS.Test.FieldLockHolder do
  @moduledoc """
  Another editor's session, as far as `KilnCMS.Collab.FieldLock` can tell: a
  process that holds a field and forwards every lock message it receives to
  the test, so a test can assert the holder was asked to flush, or was told
  who took the field — and can decide whether the holder answers.

  Deliberately NOT a LiveView. The lock keys a holder on its pid, so a plain
  process is a complete stand-in for "somebody else has this field", and a
  test that needs the real flush handshake mounts a second editor instead.
  """

  alias KilnCMS.Collab.FieldLock

  @default_user %{id: "other-editor", name: "bob"}

  @doc """
  Hold `field` on `topic` from a fresh process. Returns `{pid, result}` where
  `result` is what `acquire/4` answered (`:ok`, or `{:held, holder}` when the
  field was already somebody's). Lock messages sent to the holder arrive at
  the test as `{:holder, pid, message}`.
  """
  def hold(topic, field, user \\ @default_user) do
    test = self()

    pid =
      spawn_link(fn ->
        result = FieldLock.acquire(topic, field, user, self())
        send(test, {:acquired, self(), result})
        loop(test, topic)
      end)

    receive do
      {:acquired, ^pid, result} -> {pid, result}
    after
      1_000 -> raise "the holder never acquired #{inspect(field)}"
    end
  end

  @doc "The holder blurs `field`. Returns once the lock has let go."
  def release(pid, field) do
    ref = make_ref()
    send(pid, {:release, field, self(), ref})

    receive do
      {:released, ^ref} -> :ok
    after
      1_000 -> raise "the holder never released #{inspect(field)}"
    end
  end

  @doc "The holder's client answered the flush; the lock may transfer."
  def flushed(pid, field), do: send(pid, {:flushed, field})

  @doc "The holder's tab is gone: its process exits."
  def leave(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp loop(test, topic) do
    receive do
      {:release, field, from, ref} ->
        FieldLock.release(topic, field, self())
        send(from, {:released, ref})
        loop(test, topic)

      {:flushed, field} ->
        FieldLock.flushed(topic, field)
        loop(test, topic)

      message ->
        send(test, {:holder, self(), message})
        loop(test, topic)
    end
  end
end
