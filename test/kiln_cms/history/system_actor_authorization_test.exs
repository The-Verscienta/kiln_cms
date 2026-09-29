defmodule KilnCMS.History.SystemActorAuthorizationTest do
  @moduledoc """
  What the History API is *authorized* to do, now that it reads and writes the
  event log as `History.system/0` instead of `authorize?: false` (#1659), and
  that every call fails CLOSED when that grant is gone.

  Every grant has a refusal next to it: the system appends, anonymizes and
  reads one document's events, but may not list events across documents; no
  person, admin included, may append or anonymize.

  The fail-closed tests assert on what a filtered read could NOT produce: a
  raise, and the log left exactly as it was. `next_seq/2` is a uniqueness
  decision, so the test that matters most is that a refused read never hands
  out a sequence number.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  require Ash.Query

  alias KilnCMS.History
  alias KilnCMS.History.DocumentEvent
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp doc_id, do: Ash.UUID.generate()
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "hsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp record!(id, kind, payload, opts \\ []) do
    {:ok, event} =
      History.record(:page, id, kind, payload, Keyword.put_new(opts, :org_id, org_id()))

    event
  end

  # The rows themselves, read around every policy, so an assertion on them
  # never depends on the grant under test.
  defp stored(id) do
    DocumentEvent
    |> Ash.Query.filter(document_id == ^id)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!(authorize?: false, tenant: org_id())
  end

  test "History.system/0 is a system actor labelled :history" do
    assert %SystemActor{subsystem: :history} = History.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> History.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :history} = History.system()
    assert History.with_actor(nil, &History.system/0) == nil
  end

  describe "the grant" do
    test "the system appends with the next sequence number and reads one document back" do
      id = doc_id()
      first = record!(id, :snapshot, %{"blocks" => []})
      second = record!(id, :block_added, %{"block" => %{"id" => "a"}, "index" => 0})

      assert {first.seq, second.seq} == {1, 2}
      assert Enum.map(stored(id), & &1.id) == [first.id, second.id]

      assert [%{id: a}, %{id: b}] =
               History.events_for!(:page, id, actor: History.system(), tenant: org_id())

      assert {a, b} == {first.id, second.id}
    end

    test "the system may not list events across documents" do
      record!(doc_id(), :snapshot, %{"blocks" => []})

      assert_raise Ash.Error.Forbidden, fn ->
        History.list_events!(actor: History.system(), tenant: org_id(), authorize_with: :error)
      end

      assert [] == History.list_events!(actor: History.system(), tenant: org_id())
    end

    test "no person, admin included, may append or anonymize" do
      id = doc_id()
      event = record!(id, :snapshot, %{"blocks" => []}, actor_id: Ash.UUID.generate())

      for actor <- [nil, user(:editor), user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 History.append_event(
                   %{document_type: :page, document_id: id, seq: 99, kind: :snapshot},
                   actor: actor,
                   tenant: org_id()
                 )

        assert {:error, %Ash.Error.Forbidden{}} =
                 event
                 |> Ash.Changeset.for_update(:anonymize_actor, %{},
                   actor: actor,
                   tenant: org_id()
                 )
                 |> Ash.update()
      end

      assert [%{seq: 1, actor_id: actor_id}] = stored(id)
      assert actor_id == event.actor_id
    end

    test "an editor still reads the log; a viewer reads nothing" do
      id = doc_id()
      event = record!(id, :snapshot, %{"blocks" => []})

      assert [%{id: read}] =
               History.events_for!(:page, id, actor: user(:editor), tenant: org_id())

      assert read == event.id
      assert [] == History.events_for!(:page, id, actor: user(:viewer), tenant: org_id())
    end

    test "anonymize_actor/1 nulls the erased user's actor and keeps the event" do
      id = doc_id()
      erased = Ash.UUID.generate()
      record!(id, :snapshot, %{"blocks" => []}, actor_id: erased)

      assert [%{id: found}] =
               History.events_by_actor!(erased, actor: History.system(), tenant: org_id())

      assert found == hd(stored(id)).id

      assert :ok = History.anonymize_actor(erased)
      assert [%{seq: 1, actor_id: nil}] = stored(id)
    end
  end

  describe "fail closed: a lost grant never reads as \"no events\"" do
    test "next_seq raises instead of handing out a sequence number already taken" do
      id = doc_id()
      record!(id, :snapshot, %{"blocks" => []})
      record!(id, :block_added, %{"block" => %{"id" => "a"}, "index" => 0})

      assert_raise Ash.Error.Forbidden, fn ->
        History.with_actor(nil, fn ->
          History.record(:page, id, :block_removed, %{"block_id" => "a"}, org_id: org_id())
        end)
      end

      assert [1, 2] == Enum.map(stored(id), & &1.seq)
    end

    test "next_seq raises for an actor that is not the system, too" do
      id = doc_id()
      record!(id, :snapshot, %{"blocks" => []})

      assert_raise Ash.Error.Forbidden, fn ->
        History.with_actor(user(:viewer), fn ->
          History.record(:page, id, :block_added, %{"block" => %{}}, org_id: org_id())
        end)
      end

      assert [1] == Enum.map(stored(id), & &1.seq)
    end

    test "replay raises instead of folding an empty document" do
      id = doc_id()
      record!(id, :block_added, %{"block" => %{"id" => "a"}, "index" => 0})

      assert [%{"id" => "a"}] = History.replay(:page, id, org_id: org_id())

      assert_raise Ash.Error.Forbidden, fn ->
        History.with_actor(nil, fn -> History.replay(:page, id, org_id: org_id()) end)
      end
    end

    test "replay from a snapshot raises too" do
      id = doc_id()
      record!(id, :snapshot, %{"blocks" => [%{"id" => "a"}]})
      record!(id, :block_added, %{"block" => %{"id" => "b"}, "index" => 1})

      assert ["a", "b"] == Enum.map(History.replay(:page, id, org_id: org_id()), & &1["id"])

      assert_raise Ash.Error.Forbidden, fn ->
        History.with_actor(nil, fn -> History.replay(:page, id, org_id: org_id()) end)
      end
    end

    test "the erasure sweep reports itself incomplete instead of erasing nothing" do
      id = doc_id()
      erased = Ash.UUID.generate()
      record!(id, :snapshot, %{"blocks" => []}, actor_id: erased)

      log =
        capture_log(fn ->
          assert_raise RuntimeError, ~r/anonymize_actor incomplete/, fn ->
            History.with_actor(nil, fn -> History.anonymize_actor(erased) end)
          end
        end)

      assert log =~ "anonymize_actor failed for org"
      assert [%{actor_id: ^erased}] = stored(id)
    end
  end
end
