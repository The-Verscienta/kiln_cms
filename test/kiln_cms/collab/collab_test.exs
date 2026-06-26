defmodule KilnCMS.CollabTest do
  @moduledoc "Phase F — collaboration primitives over the event substrate (D5/D14)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.{Collab, History}
  alias KilnCMS.Collab.{Locks, Patch}

  defp doc_id, do: Ash.UUID.generate()

  describe "block locking" do
    test "a second editor cannot acquire a held block; the holder can re-acquire" do
      key = "page:#{doc_id()}"
      assert :ok = Locks.acquire(key, "b1", :alice)
      assert {:error, {:locked, :alice}} = Locks.acquire(key, "b1", :bob)
      assert :ok = Locks.acquire(key, "b1", :alice)
      assert {:ok, :alice} = Locks.holder(key, "b1")
    end

    test "releasing frees the block for another editor" do
      key = "page:#{doc_id()}"
      :ok = Locks.acquire(key, "b2", :alice)
      :ok = Locks.release(key, "b2", :alice)
      assert :free = Locks.holder(key, "b2")
      assert :ok = Locks.acquire(key, "b2", :bob)
    end

    test "a crashed holder process releases its lock" do
      key = "page:#{doc_id()}"
      test = self()

      pid =
        spawn(fn ->
          :ok = Locks.acquire(key, "b3", :carol)
          send(test, :acquired)
          Process.sleep(:infinity)
        end)

      assert_receive :acquired
      assert {:ok, :carol} = Locks.holder(key, "b3")

      Process.exit(pid, :kill)
      assert eventually_free?(key, "b3")
      # The freed block can be re-acquired.
      assert :ok = Locks.acquire(key, "b3", :dave)
    end
  end

  # Poll briefly: the monitor :DOWN that releases the lock is async to the kill.
  defp eventually_free?(key, block, attempts \\ 50) do
    cond do
      Locks.holder(key, block) == :free -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually_free?(key, block, attempts - 1)
    end
  end

  describe "apply_op/4" do
    test "persists the op as an event, broadcasts it, and replay reflects it" do
      id = doc_id()
      :ok = Collab.subscribe(:page, id)

      {:ok, _} =
        Collab.apply_op(
          :page,
          id,
          {:add_block, %{"id" => "a", "type" => "heading", "content" => "Hi"}, 0}
        )

      assert_receive {:block_op, %{op: {:add_block, _, 0}, seq: 1}}
      assert [%{"id" => "a"}] = History.replay(:page, id)
    end

    test "a sequence of ops folds into the expected state" do
      id = doc_id()

      Collab.apply_op(
        :page,
        id,
        {:add_block, %{"id" => "a", "type" => "heading", "content" => "A"}, 0}
      )

      Collab.apply_op(
        :page,
        id,
        {:add_block, %{"id" => "b", "type" => "heading", "content" => "B"}, 1}
      )

      Collab.apply_op(:page, id, {:reorder, ["b", "a"]})
      Collab.apply_op(:page, id, {:remove_block, "a"})

      assert Enum.map(History.replay(:page, id), & &1["id"]) == ["b"]
    end
  end

  describe "prose patch (last-write-wins)" do
    test "replaces a block's Portable Text body" do
      block = %{
        "id" => "a",
        "type" => "rich_text",
        "body" => [%{"_type" => "block", "children" => []}]
      }

      new_body = [
        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [%{"_type" => "span", "text" => "edited", "marks" => []}]
        }
      ]

      patched = Patch.apply_prose(block, %{"body" => new_body})
      assert patched["body"] == new_body
    end

    test "ignores a malformed patch" do
      block = %{"id" => "a", "body" => []}
      assert Patch.apply_prose(block, %{"nope" => 1}) == block
    end
  end
end
