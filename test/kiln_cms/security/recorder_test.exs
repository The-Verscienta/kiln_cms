defmodule KilnCMS.Security.RecorderTest do
  @moduledoc """
  The security event recorder and request context (#2241): context extraction,
  actor labelling, the in-transaction and best-effort modes, the per-IP sample
  cap, and the reusable `Changes.Record`.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.Security.Event
  alias KilnCMS.Security.Recorder

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rec-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp stored do
    Event |> Ash.Query.sort(inserted_at: :asc) |> Ash.read!(authorize?: false, tenant: org_id())
  end

  defp attach(event) do
    id = "rec-#{uniq()}"
    test = self()

    :telemetry.attach(
      id,
      event,
      fn _e, measurements, meta, _ -> send(test, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "request_context/1" do
    test "from a conn: the resolved client ip and user agent" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:remote_ip, {203, 0, 113, 9})
        |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0 Test")

      assert Recorder.request_context(conn) == %{
               ip: "203.0.113.9",
               user_agent: "Mozilla/5.0 Test"
             }
    end

    test "from a conn: IPv6 and a missing or oversized user agent" do
      conn = Map.put(Plug.Test.conn(:get, "/"), :remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
      assert %{ip: "::1", user_agent: nil} = Recorder.request_context(conn)

      long = String.duplicate("a", 900)
      conn = Plug.Conn.put_req_header(conn, "user-agent", long)
      assert String.length(Recorder.request_context(conn).user_agent) == 512
    end

    test "from connect_info: peer address, no trusted proxy so X-Forwarded-For is ignored" do
      info = %{
        peer_data: %{address: {198, 51, 100, 4}, port: 1, ssl_cert: nil},
        x_headers: [{"x-forwarded-for", "1.2.3.4"}],
        user_agent: "UA"
      }

      assert Recorder.request_context(info) == %{ip: "198.51.100.4", user_agent: "UA"}
    end

    test "from an unmounted socket: empty rather than an error" do
      assert Recorder.request_context(%Phoenix.LiveView.Socket{}) == %{ip: nil, user_agent: nil}
    end

    test "context/1 wraps it under the context key" do
      conn = Map.put(Plug.Test.conn(:get, "/"), :remote_ip, {127, 0, 0, 1})
      assert %{security_request: %{ip: "127.0.0.1"}} = Recorder.context(conn)
      assert Recorder.context_key() == :security_request
    end
  end

  describe "record/2" do
    test "a known user fills actor_id and the email label, with the request" do
      u = user()

      assert {:ok, event} =
               Recorder.record(:sign_in,
                 tenant: org_id(),
                 user: u,
                 request: %{ip: "203.0.113.1", user_agent: "UA"},
                 metadata: %{"method" => "password", "stray" => "dropped"}
               )

      assert event.actor_id == u.id
      assert event.actor_label == to_string(u.email)
      assert event.ip == "203.0.113.1"
      assert event.metadata == %{"method" => "password"}
    end

    test "an unknown account gets neither actor_id nor a label" do
      assert {:ok, event} =
               Recorder.record(:sign_in_failed,
                 tenant: org_id(),
                 user: nil,
                 request: %{ip: "203.0.113.1"}
               )

      assert event.actor_id == nil
      assert event.actor_label == nil
    end

    test "no tenant: not recorded" do
      assert Recorder.record(:sign_in, user: user()) == :skipped
      assert Recorder.record(:sign_in, tenant: nil) == :skipped
      assert stored() == []
    end

    test "the user being erased, or an anonymized one, is not recorded" do
      u = user()

      assert Recorder.record(:sign_in, tenant: org_id(), user: u, erasing_user_id: u.id) ==
               :skipped

      gone = %{u | anonymized_at: DateTime.utc_now()}
      assert Recorder.record(:sign_in, tenant: org_id(), user: gone) == :skipped
      assert stored() == []

      assert {:ok, _} =
               Recorder.record(:sign_in,
                 tenant: org_id(),
                 user: u,
                 erasing_user_id: Ecto.UUID.generate()
               )
    end

    test "inside a transaction, a rollback drops the event" do
      KilnCMS.Repo.transaction(fn ->
        assert {:ok, _} = Recorder.record(:sign_in, tenant: org_id(), user: user())
        KilnCMS.Repo.rollback(:undo)
      end)

      assert stored() == []
    end
  end

  describe "record_after_commit/2" do
    test "writes the event" do
      assert :ok = Recorder.record_after_commit(:sign_in, tenant: org_id(), user: user())
      assert [%{type: :sign_in}] = stored()
    end

    test "no tenant: skipped" do
      assert Recorder.record_after_commit(:sign_in, user: user()) == :skipped
      assert stored() == []
    end

    test "a failing write does not raise, logs and emits telemetry" do
      attach([:kiln_cms, :security, :event_failed])

      # An actor_id that is not a uuid makes the create fail.
      log =
        capture_log(fn ->
          assert :ok =
                   Recorder.record_after_commit(:sign_in,
                     tenant: org_id(),
                     user: %KilnCMS.Accounts.User{id: "not-a-uuid", email: "x@example.com"}
                   )
        end)

      assert log =~ "security event sign_in not recorded"
      assert_receive {:telemetry, _, %{count: 1}, %{type: :sign_in}}
    end

    test "held until the enclosing deferring block commits, dropped on rollback" do
      KilnCMS.AfterCommit.deferring(fn ->
        Recorder.record_after_commit(:sign_in, tenant: org_id(), user: user())
        assert stored() == []
        {:error, :rolled_back}
      end)

      assert stored() == []
    end
  end

  describe "record_sampled/2" do
    test "records up to the per-IP cap, drops and counts the rest" do
      attach([:kiln_cms, :security, :event_sampled_out])
      ip = "198.51.100.#{uniq() |> rem(250)}"
      opts = [tenant: org_id(), request: %{ip: ip}, limit: 2]

      for _ <- 1..4, do: assert(:ok = Recorder.record_sampled(:sign_in_failed, opts))

      assert length(stored()) == 2
      assert_receive {:telemetry, _, %{count: 1}, %{type: :sign_in_failed}}
    end

    test "a lazy user is not resolved for a dropped event" do
      ip = "198.51.100.#{uniq() |> rem(250)}"
      test_pid = self()

      lazy = fn ->
        send(test_pid, :resolved)
        nil
      end

      opts = [tenant: org_id(), request: %{ip: ip}, limit: 1, user: lazy]

      Recorder.record_sampled(:sign_in_failed, opts)
      assert_received :resolved
      Recorder.record_sampled(:sign_in_failed, opts)
      refute_received :resolved
    end

    test "another IP has its own cap" do
      a = [tenant: org_id(), request: %{ip: "192.0.2.#{rem(uniq(), 250)}a"}, limit: 1]
      b = [tenant: org_id(), request: %{ip: "192.0.2.#{rem(uniq(), 250)}b"}, limit: 1]

      Recorder.record_sampled(:sign_in_failed, a)
      Recorder.record_sampled(:sign_in_failed, a)
      Recorder.record_sampled(:sign_in_failed, b)

      assert length(stored()) == 2
    end

    test "a blocked address and a key over a limit are sampled once per key per window" do
      for type <- [:ip_block_refused, :api_key_rate_limited] do
        window = KilnCMS.Test.BudgetWindow.fresh_window_ms()
        key = "#{type}-#{uniq()}"
        opts = [tenant: org_id(), sample_key: key, limit: 1, scale: window]
        other = Keyword.put(opts, :sample_key, "#{key}-other")

        for _ <- 1..3, do: assert(:ok = Recorder.record_sampled(type, opts))
        assert :ok = Recorder.record_sampled(type, other)

        assert Enum.count(stored(), &(&1.type == type)) == 2, inspect(type)
      end
    end

    test "lockouts are never sampled away" do
      opts = [tenant: org_id(), request: %{ip: "203.0.113.77"}, limit: 1]
      for _ <- 1..3, do: Recorder.record_sampled(:sign_in_locked, opts)
      assert length(stored()) == 3
    end

    test "no tenant: skipped without charging the cap" do
      assert Recorder.record_sampled(:sign_in_failed, request: %{ip: "203.0.113.5"}) == :skipped
    end
  end

  describe "Changes.Record" do
    test "records with the request context, actor, target and metadata" do
      u = user()
      ctx = %{security_request: %{ip: "203.0.113.50", user_agent: "UA"}}

      thing =
        Ash.create!(KilnCMS.Test.SecurityRecorder.Thing, %{name: "Key"},
          action: :in_txn,
          tenant: org_id(),
          actor: u,
          context: ctx
        )

      assert [event] = stored()
      assert event.type == :passkey_added
      assert event.actor_id == u.id
      assert event.ip == "203.0.113.50"
      assert event.target_id == thing.id
      assert event.metadata == %{"name" => "Key"}
    end

    test "after_commit mode records, and without a tenant records nothing" do
      Ash.create!(KilnCMS.Test.SecurityRecorder.Thing, %{name: "k"},
        action: :committed,
        tenant: org_id()
      )

      assert [%{type: :passkey_removed, actor_id: nil}] = stored()

      Ash.create!(KilnCMS.Test.SecurityRecorder.Thing, %{name: "k"}, action: :in_txn)
      assert length(stored()) == 1
    end
  end
end
