defmodule KilnCMS.Accounts.SignInUnlockAsyncTest do
  @moduledoc """
  The sign-in unlock request's hand-off (#2250), with the task supervisor it
  really uses. The rest of the suite runs the hand-off inline
  (`config/test.exs`); here it is turned back on, so the lookup and the mail
  happen in a task under `KilnCMS.Accounts.SignInUnlock.TaskSupervisor`, which
  reaches this test's sandbox connection through shared mode.

  `async: false`: it turns the hand-off on and lowers `AccountThrottle`'s
  budget with `Application.put_env/3`, both node-wide, and it fills a
  node-wide supervisor.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.EnumerationAssertions, only: [count_calls: 2]
  import KilnCMS.Test.Eventually
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SignInUnlock
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Recorder

  @budget 3

  setup do
    throttle = Application.get_env(:kiln_cms, AccountThrottle, [])
    unlock = Application.get_env(:kiln_cms, SignInUnlock, [])
    Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(throttle, :budget, @budget))
    Application.put_env(:kiln_cms, SignInUnlock, Keyword.put(unlock, :async, true))

    on_exit(fn ->
      Application.put_env(:kiln_cms, AccountThrottle, throttle)
      Application.put_env(:kiln_cms, SignInUnlock, unlock)
    end)

    :ok
  end

  defp email, do: "unlock-async-#{System.unique_integer([:positive])}@example.com"

  defp paused_user! do
    address = email()

    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    Enum.each(1..@budget, fn _ -> AccountThrottle.consume(address) end)
    address
  end

  defp ctx do
    %{
      Recorder.tenant_key() => Accounts.default_org_id(),
      Recorder.context_key() => %{ip: "203.0.113.9", user_agent: nil}
    }
  end

  defp request(address),
    do: Accounts.request_sign_in_unlock(address, authorize?: false, context: ctx())

  # Every hand-off has finished, so nothing touches the sandbox after the test.
  defp settle do
    eventually(fn -> Task.Supervisor.children(SignInUnlock.task_supervisor()) == [] end)
  end

  test "a paused account is mailed through the real hand-off" do
    address = paused_user!()

    assert :ok = request(address)

    eventually(fn ->
      ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)) == 1
    end)

    settle()
    drain_oban()

    assert_email_sent(fn mail -> mail.to == [{"", address}] end)
  end

  test "the request process does the same work for a known and an unknown address" do
    known = paused_user!()
    unknown = email()

    traced = [
      {Task.Supervisor, :start_child, 2},
      {Accounts, :get_user_by_email, 2},
      {AccountThrottle, :sign_in_paused?, 1},
      {AccountThrottle, :allow_mail?, 2},
      {SignInUnlock, :mint, 2}
    ]

    {:ok, known_calls} = count_calls(fn -> request(known) end, traced)
    settle()
    {:ok, unknown_calls} = count_calls(fn -> request(unknown) end, traced)
    settle()

    assert known_calls == unknown_calls
    # The hand-off, and nothing that looks at the address, ran here.
    assert known_calls[{Task.Supervisor, :start_child, 2}] == 1
    assert known_calls[{Accounts, :get_user_by_email, 2}] == 0
    assert known_calls[{AccountThrottle, :sign_in_paused?, 1}] == 0
    assert known_calls[{SignInUnlock, :mint, 2}] == 0

    # The task did the work for the known address, off the request process.
    drain_oban()
    assert_email_sent(fn mail -> mail.to == [{"", known}] end)
    refute_email_sent()
  end

  test "a full supervisor drops the request, answers :ok, and logs once" do
    address = paused_user!()
    supervisor = SignInUnlock.task_supervisor()
    parent = self()

    # Fill every slot with a task that waits to be told to finish.
    blockers =
      Stream.repeatedly(fn ->
        Task.Supervisor.start_child(supervisor, fn ->
          send(parent, {:blocking, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)
      |> Enum.take_while(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, pid} -> pid end)

    on_exit(fn -> Enum.each(blockers, &send(&1, :finish)) end)
    assert length(blockers) == 20

    log =
      capture_log(fn ->
        assert :ok = request(address)
        assert :ok = request(address)
      end)

    # Two drops, one line: the log is throttled to once a minute.
    assert length(String.split(log, "Dropped a sign-in unlock request")) == 2

    Enum.each(blockers, &send(&1, :finish))
    settle()
    drain_oban()
    refute_email_sent()
    assert ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)) == 0
  end
end
