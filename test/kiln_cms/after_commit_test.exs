defmodule KilnCMS.AfterCommitTest do
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.AfterCommit
  alias KilnCMS.Repo

  # Unboxed, so each test's transaction is a real outermost one that really
  # commits or rolls back.
  defp outermost(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp mark(tag), do: AfterCommit.run(fn -> send(self(), tag) end)

  test "outside any block, an effect runs at once" do
    assert :ok = mark(:now)
    assert_received :now
  end

  test "held until the transaction commits, then run in order" do
    result =
      outermost(fn ->
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            mark(:first)
            mark(:second)
            refute_received :first
            :done
          end)
        end)
      end)

    assert result == {:ok, :done}
    assert {:messages, [:first, :second]} = Process.info(self(), :messages)
  end

  test "dropped when the transaction rolls back" do
    result =
      outermost(fn ->
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            mark(:never)
            Repo.rollback(:nope)
          end)
        end)
      end)

    assert result == {:error, :nope}
    refute_received :never
  end

  test "dropped, and the queue cleared, when the block raises" do
    assert_raise RuntimeError, fn ->
      outermost(fn ->
        AfterCommit.deferring(fn ->
          Repo.transaction(fn ->
            mark(:never)
            raise "boom"
          end)
        end)
      end)
    end

    refute_received :never
    mark(:after)
    assert_received :after
  end

  test "a nested block joins the outer one: only the outer commit counts" do
    outermost(fn ->
      AfterCommit.deferring(fn ->
        Repo.transaction(fn ->
          {:ok, _} = AfterCommit.deferring(fn -> Repo.transaction(fn -> mark(:inner) end) end)
          refute_received :inner
          Repo.rollback(:outer)
        end)
      end)
    end)

    refute_received :inner
  end

  test "inside a transaction nobody wrapped, nothing is held" do
    # There is no commit here for the block to wait for: the transaction
    # around it is someone else's.
    outermost(fn ->
      Repo.transaction(fn ->
        AfterCommit.deferring(fn ->
          mark(:now)
          assert_received :now
          {:ok, nil}
        end)
      end)
    end)
  end

  test "one failing effect is logged and does not stop the rest" do
    log =
      capture_log(fn ->
        outermost(fn ->
          AfterCommit.deferring(fn ->
            Repo.transaction(fn ->
              AfterCommit.run(fn -> raise "effect failed" end)
              mark(:still_runs)
            end)
          end)
        end)
      end)

    assert log =~ "effect failed"
    assert_received :still_runs
  end

  test "capture holds effects back for a replay, leaving an outer queue alone" do
    outermost(fn ->
      AfterCommit.deferring(fn ->
        Repo.transaction(fn ->
          mark(:outer)

          {:result, captured} =
            AfterCommit.capture(fn ->
              mark(:captured)
              :result
            end)

          assert length(captured) == 1
          AfterCommit.replay(captured)
          refute_received :captured
        end)
      end)
    end)

    assert {:messages, [:outer, :captured]} = Process.info(self(), :messages)
  end
end
