defmodule KilnCMS.HistoryTest do
  @moduledoc "Phase G — event log: state is a fold over events; time-travel (D14)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.History

  defp doc_id, do: Ash.UUID.generate()

  defp record(id, kind, payload), do: {:ok, _} = History.record(:page, id, kind, payload)

  describe "replay/3" do
    test "folds events into the current block tree" do
      id = doc_id()

      record(id, :snapshot, %{"blocks" => [%{"id" => "a", "type" => "heading", "content" => "A"}]})

      record(id, :block_added, %{
        "block" => %{"id" => "b", "type" => "rich_text", "content" => "B"},
        "index" => 1
      })

      record(id, :block_added, %{
        "block" => %{"id" => "c", "type" => "quote", "content" => "C"},
        "index" => 2
      })

      record(id, :block_updated, %{
        "block_id" => "a",
        "block" => %{"id" => "a", "type" => "heading", "content" => "A2"}
      })

      record(id, :blocks_reordered, %{"order" => ["c", "b", "a"]})
      record(id, :block_removed, %{"block_id" => "b"})

      blocks = History.replay(:page, id)

      assert Enum.map(blocks, & &1["id"]) == ["c", "a"]
      assert Enum.find(blocks, &(&1["id"] == "a"))["content"] == "A2"
    end

    test "is empty for a document with no events" do
      assert History.replay(:page, doc_id()) == []
    end
  end

  describe "time-travel" do
    test "replay upto_seq reconstructs an intermediate state" do
      id = doc_id()

      record(id, :snapshot, %{"blocks" => [%{"id" => "a", "type" => "heading", "content" => "A"}]})

      record(id, :block_added, %{"block" => %{"id" => "b", "type" => "heading", "content" => "B"}})

      record(id, :block_removed, %{"block_id" => "a"})

      # After event 2 (the add), before the remove: both blocks present.
      past = History.replay(:page, id, upto_seq: 2)
      assert Enum.map(past, & &1["id"]) == ["a", "b"]

      # Current state: "a" removed.
      assert Enum.map(History.replay(:page, id), & &1["id"]) == ["b"]
    end

    test "preview_at renders a past state via the typed serializers" do
      id = doc_id()

      record(id, :snapshot, %{
        "blocks" => [
          %{"id" => "a", "type" => "heading", "content" => "Old", "data" => %{"level" => 2}}
        ]
      })

      record(id, :block_updated, %{
        "block_id" => "a",
        "block" => %{
          "id" => "a",
          "type" => "heading",
          "content" => "New",
          "data" => %{"level" => 2}
        }
      })

      {:ok, old} = History.preview_at(:page, id, upto_seq: 1)
      {:ok, now} = History.preview_at(:page, id)

      assert old.web["html"] == "<h2>Old</h2>"
      assert now.web["html"] == "<h2>New</h2>"
    end
  end

  describe "record/5" do
    test "assigns monotonically increasing per-document sequence numbers" do
      id = doc_id()
      {:ok, e1} = History.record(:page, id, :snapshot, %{"blocks" => []})
      {:ok, e2} = History.record(:page, id, :block_added, %{"block" => %{"id" => "x"}})

      assert e1.seq == 1
      assert e2.seq == 2
    end
  end
end
