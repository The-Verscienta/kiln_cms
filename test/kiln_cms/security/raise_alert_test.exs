defmodule KilnCMS.Security.RaiseAlertTest do
  @moduledoc """
  `KilnCMS.Security.Changes.RaiseAlert` (#2245): recording an audit event
  claims the alerts it raises, in the event's transaction — through the real
  emit sites, not by calling the gate.

  `async: false`: alerts are turned on (`KilnCMS.Test.SecurityAlerts.enable/0`,
  an `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Security.Changes.RaiseAlert
  alias KilnCMS.Test.SecurityAlerts

  @moduletag :capture_log

  setup do
    SecurityAlerts.enable()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "raise-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role
    })
  end

  defp ctx(org_id), do: AuthEvents.context(Plug.Test.conn(:get, "/"), org_id)

  defp dispatches, do: SecurityAlerts.dispatches()

  defp events(org_id, type) do
    # authorize?: false — reading the log back in a test.
    Security.list_events!(tenant: org_id, authorize?: false) |> Enum.filter(&(&1.type == type))
  end

  test "a membership created as admin claims the site's new_admin window" do
    org = org("raise-new-admin")

    {:ok, _} =
      Accounts.create_org_membership(
        %{organization_id: org.id, user_id: user(:viewer).id, role: :admin},
        actor: user(:admin),
        context: ctx(org.id)
      )

    [event] = events(org.id, :role_granted)

    assert [dispatch] = dispatches()
    assert dispatch["scope"] == org.id
    assert dispatch["kind"] == "new_admin"
    assert dispatch["channel"] == "site"
    assert dispatch["org_id"] == org.id
    assert dispatch["first_event_id"] == event.id
  end

  test "an emitter that rolls back leaves no alert behind" do
    org = org("raise-rollback")

    {:error, :undone} =
      Repo.transaction(fn ->
        {:ok, _} =
          Accounts.create_org_membership(
            %{organization_id: org.id, user_id: user(:viewer).id, role: :admin},
            actor: user(:admin),
            context: ctx(org.id)
          )

        assert [_claimed] = dispatches()
        Repo.rollback(:undone)
      end)

    assert dispatches() == []
  end

  test "a second admin in the same window is left for the summary" do
    org = org("raise-debounce")
    admin = user(:admin)

    for _ <- 1..3 do
      {:ok, _} =
        Accounts.create_org_membership(
          %{organization_id: org.id, user_id: user(:viewer).id, role: :admin},
          actor: admin,
          context: ctx(org.id)
        )
    end

    assert length(events(org.id, :role_granted)) == 3
    assert [%{"kind" => "new_admin"}] = dispatches()
  end

  test "an account made admin is a platform alert, whatever the site turned off" do
    org = org("raise-platform")
    site_admin = user(:viewer)
    member!(site_admin, org.id, :admin)

    CMS.save_site_security_alerts!(
      %{disabled_kinds: Enum.map(KilnCMS.Security.Alerts.site_kinds(), &to_string/1)},
      actor: site_admin,
      tenant: org.id
    )

    # Turning every kind off was itself a notice; only the grant is asserted.
    {:ok, _} =
      Accounts.manage_user_access(user(:editor), %{role: :admin},
        actor: user(:admin),
        context: ctx(org.id)
      )

    assert [dispatch] = Enum.filter(dispatches(), &(&1["channel"] == "platform"))
    assert dispatch["scope"] == "platform"
    assert dispatch["kind"] == "new_admin"
    # Bell rows for the platform go in the default org.
    assert dispatch["org_id"] == Accounts.default_org_id()
  end

  test "a temporary admin grant is a new admin; taking the role away is platform_role_changed" do
    admin = user(:admin)
    subject = user(:editor)
    expires = DateTime.add(DateTime.utc_now(), 2, :hour)

    {:ok, _} =
      Accounts.grant_user_temporary_role(
        subject,
        %{granted_role: :admin, granted_role_expires_at: expires},
        actor: admin,
        context: ctx(Accounts.default_org_id())
      )

    demoted = user(:admin)

    {:ok, _} =
      Accounts.manage_user_access(demoted, %{role: :editor},
        actor: admin,
        context: ctx(Accounts.default_org_id())
      )

    kinds = dispatches() |> Enum.map(&{&1["scope"], &1["kind"]}) |> Enum.sort()
    assert kinds == [{"platform", "new_admin"}, {"platform", "platform_role_changed"}]
  end

  test "a platform admin removing a site admin raises a notice; a self-demotion does not" do
    org = org("raise-removed")
    platform_admin = user(:admin)
    removed = user(:viewer)
    membership = member!(removed, org.id, :admin)

    :ok =
      Accounts.remove_org_membership(membership,
        actor: platform_admin,
        context: ctx(org.id)
      )

    assert [notice] = dispatches()
    assert notice["channel"] == "notice"
    assert notice["kind"] == "alerts_silenced"
    assert notice["scope"] == "notice:" <> notice["id"]
    assert notice["org_id"] == org.id
    assert notice["notice"] == %{"change" => "admin_removed", "actor_id" => platform_admin.id}
  end

  test "an account raised below admin on a site's host alerts nobody on that site" do
    site_b = org("raise-platform-editor")
    member!(user(:viewer), site_b.id, :admin)
    platform_admin = user(:admin)

    {:ok, _} =
      Accounts.manage_user_access(user(:viewer), %{role: :editor},
        actor: platform_admin,
        context: ctx(site_b.id)
      )

    {:ok, _} =
      Accounts.grant_user_temporary_role(
        user(:viewer),
        %{
          granted_role: :editor,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
        },
        actor: platform_admin,
        context: ctx(site_b.id)
      )

    # Both raises are in site B's log, where the platform admin was browsing...
    assert [_] = events(site_b.id, :role_granted)
    assert [_] = events(site_b.id, :elevation_granted)

    # ...and neither is site B's alert.
    assert dispatches() == []
  end

  test "a live admin grant replaced by a lower one raises the admin-loss notice" do
    org = org("raise-grant-replaced")
    member!(user(:viewer), org.id, :admin)
    platform_admin = user(:admin)
    subject = user(:viewer)
    later = DateTime.add(DateTime.utc_now(), 2, :hour)

    membership =
      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: subject.id,
        role: :viewer,
        granted_role: :admin,
        granted_role_expires_at: later
      })

    {:ok, _} =
      Accounts.grant_membership_temporary_role(
        membership,
        %{granted_role: :editor, granted_role_expires_at: later},
        actor: platform_admin,
        context: ctx(org.id)
      )

    assert [revoked] = events(org.id, :role_revoked)

    assert revoked.metadata == %{
             "role" => "admin",
             "level" => "site",
             "change" => "grant_revoked"
           }

    assert [notice] = Enum.filter(dispatches(), &(&1["channel"] == "notice"))

    assert notice["notice"] == %{
             "change" => "admin_grant_revoked",
             "actor_id" => platform_admin.id
           }
  end

  test "an expired admin grant lowered, or a lower grant raised, takes no admin power away" do
    org = org("raise-grant-not-replaced")
    platform_admin = user(:admin)
    later = DateTime.add(DateTime.utc_now(), 2, :hour)

    lapsed =
      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: user(:viewer).id,
        role: :viewer,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
      })

    raised =
      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: user(:viewer).id,
        role: :viewer,
        granted_role: :editor,
        granted_role_expires_at: later
      })

    for {membership, role} <- [{lapsed, :editor}, {raised, :admin}] do
      {:ok, _} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: role, granted_role_expires_at: later},
          actor: platform_admin,
          context: ctx(org.id)
        )
    end

    assert events(org.id, :role_revoked) == []
    assert Enum.filter(dispatches(), &(&1["channel"] == "notice")) == []
  end

  # The suite's seam (`enabled: false` in config/test.exs) stops the window
  # claims only, so every emitter test still writes its notices.
  test "with alerts off, a derived notice is still raised and an alert is not" do
    Application.put_env(:kiln_cms, KilnCMS.Security.Alerts, enabled: false)

    org = org("raise-off")
    platform_admin = user(:admin)

    {:ok, _} =
      Accounts.create_org_membership(
        %{organization_id: org.id, user_id: user(:viewer).id, role: :admin},
        actor: platform_admin,
        context: ctx(org.id)
      )

    assert dispatches() == []

    :ok =
      Accounts.remove_org_membership(member!(user(:viewer), org.id, :admin),
        actor: platform_admin,
        context: ctx(org.id)
      )

    assert [%{"channel" => "notice", "notice" => %{"change" => "admin_removed"}}] = dispatches()
  end

  test "a person changing the site's mail relay raises a notice; a system write does not" do
    org = org("raise-relay")
    site_admin = user(:viewer)
    member!(site_admin, org.id, :admin)

    CMS.save_site_mail_relay!(%{host: "smtp.example.com", from_email: "news@site.example"},
      tenant: org.id,
      authorize?: false
    )

    assert dispatches() == []

    CMS.save_site_mail_relay!(%{host: "smtp.other.example", from_email: "news@site.example"},
      tenant: org.id,
      actor: site_admin
    )

    assert [%{"notice" => %{"change" => "mail_relay_changed"}}] = dispatches()
  end

  test "a derived notice that cannot be written raises, where a failed alert claim does not" do
    relay = %{
      id: Ecto.UUID.generate(),
      type: :org_setting_changed,
      metadata: %{"setting" => "site_mail_relay"},
      actor_id: nil,
      target_id: nil,
      # An org id that is no uuid: both writes fail in SQL.
      org_id: "not-a-uuid"
    }

    lockout = %{relay | type: :sign_in_locked, metadata: %{}}

    # Raising aborts the event's transaction, and the emitter's with it.
    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> RaiseAlert.raise_alerts(relay, %{}) end)
    end

    # A best-effort claim is logged and the transaction goes on.
    assert {:ok, :ok} = Repo.transaction(fn -> RaiseAlert.raise_alerts(lockout, %{}) end)

    # Unless the recording said the alert is required.
    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        RaiseAlert.raise_alerts(lockout, %{security_alert_required: true})
      end)
    end
  end

  describe "outside the sandbox's transaction (B3)" do
    alias Ecto.Adapters.SQL.Sandbox

    setup do
      window = KilnCMS.Test.BudgetWindow.fresh_window_ms()
      Application.put_env(:kiln_cms, :security_alert_window_ms, window)
      on_exit(fn -> Application.delete_env(:kiln_cms, :security_alert_window_ms) end)

      org_id = Sandbox.unboxed_run(Repo, &Accounts.default_org_id/0)
      target = Ecto.UUID.generate()

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!(
            "DELETE FROM security_alert_dispatches WHERE first_event_id IN " <>
              "(SELECT id FROM security_events WHERE target_id = $1::text::uuid)",
            [target]
          )

          Repo.query!("DELETE FROM security_events WHERE target_id = $1::text::uuid", [target])
        end)
      end)

      %{org_id: org_id, target: target}
    end

    defp committed(target) do
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: rows} =
          Repo.query!(
            "SELECT d.kind FROM security_alert_dispatches d JOIN security_events e " <>
              "ON e.id = d.first_event_id WHERE e.target_id = $1::text::uuid",
            [target]
          )

        List.flatten(rows)
      end)
    end

    test "record_after_commit with no transaction around it claims in the event's own",
         %{org_id: org_id, target: target} do
      Sandbox.unboxed_run(Repo, fn ->
        refute Repo.in_transaction?()

        :ok =
          KilnCMS.Security.Recorder.record_after_commit(:sign_in_locked,
            tenant: org_id,
            target_type: "user",
            target_id: target
          )
      end)

      assert committed(target) == ["lockout"]
    end

    test "an emitter's transaction commits the claim with it, or takes it back",
         %{org_id: org_id, target: target} do
      record = fn ->
        {:ok, _} =
          KilnCMS.Security.Recorder.record(:second_factor_removed,
            tenant: org_id,
            target_type: "user",
            target_id: target
          )
      end

      Sandbox.unboxed_run(Repo, fn ->
        {:error, :undone} =
          Repo.transaction(fn ->
            record.()
            Repo.rollback(:undone)
          end)
      end)

      assert committed(target) == []

      Sandbox.unboxed_run(Repo, fn -> {:ok, _} = Repo.transaction(record) end)
      assert committed(target) == ["two_factor_disabled"]
    end
  end
end
