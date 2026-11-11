defmodule KilnCMS.Accounts.Changes.CheckBreachedPasswordTest do
  @moduledoc """
  The breached-password check on all four password-setting actions of `User`
  (#2240): register, change, reset and the first-run bootstrap.

  Covers the policy x target-tier x verdict matrix on each action, that
  `:off` and the kill switch make no call, that every error class fails open,
  that an invalid changeset and `AshPhoenix.Form.validate/2` never call out,
  that nothing identifying the password reaches a log or a telemetry event,
  and that the bootstrap lookup happens outside its advisory-locked
  transaction.

  `async: false`: the stub, the policy and the telemetry handlers are
  node-wide (`KilnCMS.BreachedPasswordFixtures`).
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.BreachedPasswordFixtures
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Bootstrap
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @old_password "password123456"
  @event [:kiln_cms, :password, :breach_check]
  @actions [:register, :change, :reset, :bootstrap]

  defp email, do: "hibp-#{System.unique_integer([:positive])}@example.com"

  defp account(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: email(),
      hashed_password: Bcrypt.hash_pwd_salt(@old_password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp strategy, do: AshAuthentication.Info.strategy!(User, :password)

  # The four actions behind one signature: `run(action, password, tier, opts)`
  # returns `{:ok, record}` or `{:error, error}`; `tier` is the target's.
  defp run(:register, password, _tier, opts) do
    AshAuthentication.Strategy.action(
      strategy(),
      :register,
      %{"email" => email(), "password" => password, "password_confirmation" => password},
      opts
    )
  end

  defp run(:change, password, tier, opts) do
    user = account(tier)

    user
    |> Ash.Changeset.for_update(
      :change_password,
      %{current_password: @old_password, password: password, password_confirmation: password},
      Keyword.merge([actor: user], opts)
    )
    |> Ash.update()
  end

  defp run(:reset, password, tier, opts) do
    user = account(tier)
    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy(), user)

    AshAuthentication.Strategy.action(
      strategy(),
      :reset,
      %{"reset_token" => token, "password" => password, "password_confirmation" => password},
      opts
    )
  end

  # Bootstrap returns its notice beside the user (the reload drops metadata);
  # fold it back so the four read the same.
  defp run(:bootstrap, password, _tier, _opts) do
    case Bootstrap.create_first_admin(%{
           email: email(),
           password: password,
           password_confirmation: password
         }) do
      {:ok, user, notices} ->
        if :password_breach in notices,
          do: {:ok, Ash.Resource.put_metadata(user, :password_breach, %{status: :breached})},
          else: {:ok, user}

      other ->
        other
    end
  end

  # Which tiers an action can be run for.
  defp tiers(:register), do: [:viewer]
  defp tiers(:bootstrap), do: [:admin]
  defp tiers(_action), do: [:viewer, :editor, :admin]

  defp breached?(%{__metadata__: %{password_breach: %{status: :breached}}}), do: true
  defp breached?(_record), do: false

  defp blocked?({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :password}, &1))

  defp blocked?(_other), do: false

  defp flush do
    receive do
      {:hibp_request, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  describe "policy x target tier x verdict, on every action" do
    for action <- @actions, policy <- [:off, :warn, :block], verdict <- [:breached, :clean] do
      test "#{action}: #{policy} / #{verdict}" do
        matrix(unquote(action), unquote(policy), unquote(verdict))
      end
    end

    defp matrix(action, policy, verdict) do
      for tier <- tiers(action) do
        password = password()

        body =
          if verdict == :breached,
            do: breached_body(password, 77),
            else: clean_body(password)

        enable!(&ok(&1, body), default_policy: policy)
        result = run(action, password, tier, [])

        cond do
          policy == :off ->
            assert {:ok, record} = result
            refute breached?(record)
            refute_received {:hibp_request, _, _}

          verdict == :clean ->
            assert {:ok, record} = result
            refute breached?(record)
            assert_received {:hibp_request, _, _}

          policy == :block and tier == :admin ->
            assert blocked?(result)
            assert_received {:hibp_request, _, _}

          true ->
            # warn, or block for a target who is not an admin
            assert {:ok, record} = result
            assert breached?(record)
            assert_received {:hibp_request, _, _}
        end

        flush()
      end
    end
  end

  describe "the block error" do
    test "is an InvalidAttribute on :password carrying neither password nor value" do
      password = password()
      enable!(&ok(&1, breached_body(password, 9)), default_policy: :block)

      assert {:error, %Ash.Error.Invalid{errors: [error]} = wrapper} =
               run(:change, password, :admin, [])

      assert %Ash.Error.Changes.InvalidAttribute{field: :password, value: nil} = error
      assert error.message =~ "known data breach"
      refute inspect(wrapper) =~ password
    end

    test "leaves the account's password alone" do
      password = password()
      enable!(&ok(&1, breached_body(password, 9)), default_policy: :block)
      user = account(:admin)

      assert {:error, _} =
               user
               |> Ash.Changeset.for_update(
                 :change_password,
                 %{
                   current_password: @old_password,
                   password: password,
                   password_confirmation: password
                 },
                 actor: user
               )
               |> Ash.update()

      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.hashed_password == user.hashed_password
    end
  end

  describe "a site's own row" do
    setup do
      %{org: org("hibp-site")}
    end

    defp save_policy!(org, policy) do
      CMS.save_site_password_policy!(%{breached_password_policy: policy},
        actor: account(:admin),
        tenant: org
      )
    end

    test "a block row refuses a breached password for an admin of that org", %{org: org} do
      save_policy!(org, :block)
      password = password()
      enable!(&ok(&1, breached_body(password, 3)))

      assert blocked?(run(:change, password, :admin, tenant: org))
    end

    test "an org-admin by membership (viewer globally) is refused", %{org: org} do
      save_policy!(org, :block)
      member = account(:viewer)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: member.id,
        role: :admin
      })

      password = password()
      enable!(&ok(&1, breached_body(password, 3)))

      result =
        member
        |> Ash.Changeset.for_update(
          :change_password,
          %{
            current_password: @old_password,
            password: password,
            password_confirmation: password
          },
          actor: member,
          tenant: org
        )
        |> Ash.update()

      assert blocked?(result)
    end

    test "the same account in an org with no row only warns", %{org: org} do
      password = password()
      enable!(&ok(&1, breached_body(password, 3)))
      assert {:ok, record} = run(:change, password, :admin, tenant: org)
      assert breached?(record)
    end

    test "an :off row makes no call", %{org: org} do
      save_policy!(org, :off)
      enable!(&ok(&1, ""))
      assert {:ok, _} = run(:change, password(), :admin, tenant: org)
      refute_received {:hibp_request, _, _}
    end
  end

  describe "the kill switch" do
    test "makes no outbound call on any action, whatever the policy says" do
      enable!(&ok(&1, ""), default_policy: :block, enabled: false)

      for action <- @actions do
        assert {:ok, _} = run(action, password(), hd(tiers(action)), [])
      end

      refute_received {:hibp_request, _, _}
    end
  end

  describe "failing open" do
    defp failing({:status, status}), do: &Plug.Conn.send_resp(&1, status, "x")
    defp failing({:body, body}), do: &ok(&1, body)
    defp failing({:transport, reason}), do: &Req.Test.transport_error(&1, reason)

    @failures [
      http_status: {:status, 500},
      malformed: {:body, "<html>nope</html>"},
      timeout: {:transport, :timeout},
      transport: {:transport, :econnrefused}
    ]

    for {class, failure} <- @failures, action <- @actions do
      test "#{action}: #{class} lets the password through and says so in telemetry" do
        action = unquote(action)
        class = unquote(class)
        failure = unquote(Macro.escape(failure))

        enable!(failing(failure), default_policy: :block)

        ref = :telemetry_test.attach_event_handlers(self(), [@event])

        log =
          capture_log(fn ->
            assert {:ok, record} = run(action, password(), List.last(tiers(action)), [])
            refute breached?(record)
          end)

        assert_receive {@event, ^ref, %{count: 1}, %{result: :error, reason: ^class} = meta}
        assert meta.enforcement == :allowed
        assert log =~ "breached-password lookup failed (#{class})"
      end
    end

    test "a slow server hits the overall deadline and fails open as :timeout" do
      password = password()

      enable!(
        fn conn ->
          Process.sleep(400)
          ok(conn, breached_body(password, 1))
        end,
        default_policy: :block,
        deadline: 50
      )

      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      capture_log(fn -> assert {:ok, _} = run(:change, password, :admin, []) end)
      assert_receive {@event, ^ref, _, %{result: :error, reason: :timeout}}
    end

    test "a refused settings read warns: not skipped, not blocked" do
      password = password()
      enable!(&ok(&1, breached_body(password, 5)), default_policy: :off)

      capture_log(fn ->
        result =
          KilnCMS.OrgSettings.with_actor(nil, fn -> run(:change, password, :admin, []) end)

        # Neither "no row" (the operator's :off) nor a block.
        assert {:ok, record} = result
        assert breached?(record)
      end)
    end
  end

  describe "when nothing may be sent" do
    test "mismatched confirmation never calls out (change)" do
      enable!(&ok(&1, ""))
      user = account()

      assert {:error, _} =
               user
               |> Ash.Changeset.for_update(
                 :change_password,
                 %{
                   current_password: @old_password,
                   password: password(),
                   password_confirmation: "different-1234"
                 },
                 actor: user
               )
               |> Ash.update()

      refute_received {:hibp_request, _, _}
    end

    test "a wrong current password never calls out" do
      enable!(&ok(&1, ""))
      user = account()
      pw = password()

      assert {:error, _} =
               user
               |> Ash.Changeset.for_update(
                 :change_password,
                 %{current_password: "not-the-password", password: pw, password_confirmation: pw},
                 actor: user
               )
               |> Ash.update()

      refute_received {:hibp_request, _, _}
    end

    test "a bad reset token never calls out" do
      enable!(&ok(&1, ""))
      pw = password()

      assert {:error, _} =
               AshAuthentication.Strategy.action(
                 strategy(),
                 :reset,
                 %{"reset_token" => "garbage", "password" => pw, "password_confirmation" => pw},
                 []
               )

      refute_received {:hibp_request, _, _}
    end

    test "a too-short password never calls out (register)" do
      enable!(&ok(&1, ""))

      assert {:error, _} =
               AshAuthentication.Strategy.action(
                 strategy(),
                 :register,
                 %{"email" => email(), "password" => "short", "password_confirmation" => "short"},
                 []
               )

      refute_received {:hibp_request, _, _}
    end

    test "AshPhoenix.Form.validate never calls out, on any form" do
      enable!(&ok(&1, ""))
      user = account()
      pw = password()

      register_form = AshPhoenix.Form.for_create(User, :register_with_password, as: "user")
      change_form = AshPhoenix.Form.for_update(user, :change_password, as: "user", actor: user)

      for form <- [register_form, change_form], keystroke <- ["p", "pa", "pas", pw] do
        AshPhoenix.Form.validate(form, %{
          "email" => email(),
          "current_password" => @old_password,
          "password" => keystroke,
          "password_confirmation" => keystroke
        })
      end

      refute_received {:hibp_request, _, _}
    end

    test "a bootstrap with invalid input never calls out" do
      enable!(&ok(&1, ""))

      assert {:error, _} =
               Bootstrap.create_first_admin(%{
                 email: email(),
                 password: password(),
                 password_confirmation: "does-not-match"
               })

      refute_received {:hibp_request, _, _}
    end
  end

  describe "nothing identifying leaves the node" do
    test "no log line or telemetry event carries the password, the hash, or the account" do
      password = password()
      {prefix, suffix} = BreachedPassword.split_hash(password)
      full_hash = prefix <> suffix

      enable!(&Plug.Conn.send_resp(&1, 500, "x"), default_policy: :warn)
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      user = account()

      log =
        capture_log(fn ->
          user
          |> Ash.Changeset.for_update(
            :change_password,
            %{
              current_password: @old_password,
              password: password,
              password_confirmation: password
            },
            actor: user
          )
          |> Ash.update!()
        end)

      assert log =~ "breached-password lookup failed"

      for secret <- [password, full_hash, prefix, suffix, user.id, to_string(user.email)] do
        refute log =~ secret
      end

      assert_receive {@event, ^ref, measurements, metadata}

      assert metadata |> Map.keys() |> Enum.sort() ==
               [:action, :enforcement, :policy, :reason, :result]

      assert measurements |> Map.keys() |> Enum.sort() == [:count, :duration]

      dump = inspect({measurements, metadata})

      for secret <- [password, full_hash, prefix, suffix, user.id, "range"] do
        refute dump =~ secret
      end
    end

    test "a hit logs nothing about the password either" do
      password = password()
      enable!(&ok(&1, breached_body(password, 12)))

      log = capture_log(fn -> assert {:ok, _} = run(:change, password, :viewer, []) end)
      refute log =~ password
      refute log =~ elem(BreachedPassword.split_hash(password), 1)
    end
  end

  describe "telemetry" do
    test "one event per lookup, shaped by the verdict and the enforcement" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])

      pw = password()
      enable!(&ok(&1, breached_body(pw, 5)), default_policy: :warn)
      assert {:ok, _} = run(:change, pw, :viewer, [])

      assert_receive {@event, ^ref, %{count: 1, duration: duration},
                      %{
                        result: :breached,
                        action: :change,
                        policy: :warn,
                        enforcement: :warned,
                        reason: nil
                      }}

      assert is_integer(duration) and duration >= 0

      pw2 = password()
      enable!(&ok(&1, clean_body(pw2)), default_policy: :warn)
      assert {:ok, _} = run(:register, pw2, :viewer, [])

      assert_receive {@event, ^ref, _,
                      %{result: :clean, action: :register, enforcement: :allowed}}

      pw3 = password()
      enable!(&ok(&1, breached_body(pw3, 5)), default_policy: :block)
      assert blocked?(run(:reset, pw3, :admin, []))

      assert_receive {@event, ^ref, _,
                      %{
                        result: :breached,
                        action: :reset,
                        policy: :block,
                        enforcement: :blocked
                      }}
    end

    test ":off emits nothing" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      enable!(&ok(&1, ""), default_policy: :off)
      assert {:ok, _} = run(:change, password(), :viewer, [])
      refute_receive {@event, ^ref, _, _}, 50
    end
  end

  describe "the notice survives each action's result" do
    test "register" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 5)))
      assert {:ok, user} = run(:register, pw, :viewer, [])
      assert user.__metadata__.password_breach == %{status: :breached}
      # The token the same action mints is still there.
      assert is_binary(user.__metadata__.token)
    end

    test "reset" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 5)))
      assert {:ok, user} = run(:reset, pw, :viewer, [])
      assert user.__metadata__.password_breach == %{status: :breached}
    end

    test "change" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 5)))
      assert {:ok, user} = run(:change, pw, :viewer, [])
      assert user.__metadata__.password_breach == %{status: :breached}
    end

    test "a clean password leaves no notice" do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))
      assert {:ok, user} = run(:reset, pw, :viewer, [])
      refute Map.has_key?(user.__metadata__, :password_breach)
    end
  end

  describe "Bootstrap" do
    test "returns the notice as its third element" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 5)))

      assert {:ok, %User{role: :admin}, [:password_breach]} =
               Bootstrap.create_first_admin(%{
                 email: email(),
                 password: pw,
                 password_confirmation: pw
               })
    end

    test "a clean password returns no notices" do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))

      assert {:ok, %User{}, []} =
               Bootstrap.create_first_admin(%{
                 email: email(),
                 password: pw,
                 password_confirmation: pw
               })
    end

    test "a block refuses, rolls back, and leaves the instance un-bootstrapped" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 5)), default_policy: :block)

      assert {:error, %Ash.Error.Invalid{}} =
               Bootstrap.create_first_admin(%{
                 email: email(),
                 password: pw,
                 password_confirmation: pw
               })

      refute Bootstrap.bootstrapped?()
    end

    test "the lookup happens before the advisory lock, not inside the transaction" do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))
      test = self()
      handler = "hibp-bootstrap-order-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.query =~ "pg_advisory_xact_lock", do: send(test, :lock_taken)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _user, []} =
               Bootstrap.create_first_admin(%{
                 email: email(),
                 password: pw,
                 password_confirmation: pw
               })

      {:messages, messages} = Process.info(self(), :messages)
      request = Enum.find_index(messages, &match?({:hibp_request, _, _}, &1))
      lock = Enum.find_index(messages, &(&1 == :lock_taken))

      assert request, "no lookup was made: #{inspect(messages)}"
      assert lock, "the advisory lock was never taken: #{inspect(messages)}"
      assert request < lock
    end

    test "a verdict in the context is honoured and never looked up again" do
      pw = password()
      enable!(&ok(&1, ""))

      assert {:ok, _} =
               User
               |> Ash.Changeset.for_create(
                 :bootstrap_admin,
                 %{email: email(), password: pw, password_confirmation: pw},
                 context: %{breached_password_verdict: %{outcome: :clean, policy: :warn}}
               )
               |> Ash.create()

      refute_received {:hibp_request, _, _}
    end
  end
end
