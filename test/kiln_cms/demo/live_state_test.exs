defmodule KilnCMS.Demo.LiveStateTest do
  @moduledoc """
  What a running node holds outside the database, stopped around a demo
  restore (`docs/demo-mode.md`): collaborative documents are closed and may not
  reopen, every user's sockets are evicted on both sides of the restore, and
  the per-account sign-in throttles are forgotten afterwards.

  `async: false` — the reset gate and the document supervisor are VM-global.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.User
  alias KilnCMS.Collab.Crdt
  alias KilnCMS.Demo.LiveState

  @supervisor KilnCMS.Collab.Crdt.DocSupervisor

  setup do
    on_exit(fn -> LiveState.end_local() end)
    :ok
  end

  defp doc_key, do: "collab:entry:#{Ecto.UUID.generate()}"

  test "a reset closes every open document and refuses to open another until it ends" do
    org_id = Ecto.UUID.generate()
    {:ok, pid} = Crdt.ensure_server(doc_key(), org_id)
    ref = Process.monitor(pid)
    open = length(DynamicSupervisor.which_children(@supervisor))

    assert LiveState.begin_local() == open
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    assert DynamicSupervisor.which_children(@supervisor) == []

    assert LiveState.resetting?() == true
    assert Crdt.ensure_server(doc_key(), org_id) == {:error, :unavailable}

    assert LiveState.end_local() == 0
    assert LiveState.resetting?() == false
    assert {:ok, _pid} = Crdt.ensure_server(doc_key(), org_id)
  end

  test "the per-account sign-in throttles are forgotten" do
    AccountThrottle.forget_all()
    assert AccountThrottle.consume("shared-demo@example.com") == :allow
    assert :ets.info(AccountThrottle, :size) == 1

    assert AccountThrottle.forget_all() == :ok
    assert :ets.info(AccountThrottle, :size) == 0
  end

  test "every user's sockets are evicted before the restore and again after it" do
    user =
      Ash.Seed.seed!(User, %{
        email: "demo-visitor-#{System.unique_integer([:positive])}@example.com",
        # Never used to sign in — the column is NOT NULL, and hashing a real
        # password here would only slow the test down.
        hashed_password: "not-a-real-hash",
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    topic = SessionEviction.topic(user.id)
    KilnCMSWeb.Endpoint.subscribe(topic)

    everyone = MapSet.new(Repo.query!("SELECT id::text FROM users", []).rows, fn [id] -> id end)

    quiesced = LiveState.quiesce(grace_ms: 0)

    assert quiesced.users == everyone
    assert quiesced.jobs_still_running == 0
    assert LiveState.resetting?() == true
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}

    assert LiveState.after_restore(quiesced.users) == MapSet.size(everyone)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}

    assert LiveState.resume() == :ok
    assert LiveState.resetting?() == false
  end
end
