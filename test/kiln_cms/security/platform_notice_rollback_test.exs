defmodule KilnCMS.Security.PlatformNoticeRollbackTest do
  @moduledoc """
  Turning a platform alert off fails closed (#2811): when its platform notice
  cannot be written, the save rolls back, and with it the instance security
  log's `platform_alerts_changed` event. The kind stays on, and the page
  says the save failed.

  The notice is made to fail by a trigger on `security_alert_dispatches` that
  refuses a `platform_notice` row. Nothing else in the save can be told to
  fail there.

  Tagged `:table_lock` and **excluded from the normal run**: `CREATE TRIGGER`
  locks `security_alert_dispatches` until the sandbox transaction rolls back,
  and every other connection's alert claim queues behind it (see
  `test/test_helper.exs`). CI runs it in its own pass
  (`mix test --only table_lock`). The trigger rolls back with the sandbox.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts

  @moduletag :table_lock
  @moduletag :capture_log

  @password "platform-notice-rollback-123"

  setup do
    Repo.query!("""
    CREATE FUNCTION pg_temp.refuse_platform_notice() RETURNS trigger AS $$
    BEGIN
      IF NEW.channel = 'platform_notice' THEN
        RAISE EXCEPTION 'platform_notice refused by the test';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER refuse_platform_notice BEFORE INSERT ON security_alert_dispatches
    FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_platform_notice()
    """)

    platform =
      Ash.Seed.seed!(User, %{
        email: "platform-notice-rollback-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{platform: platform}
  end

  defp platform_alerts_changed do
    # authorize?: false — reading the instance log back in a test.
    Security.list_instance_events!(authorize?: false)
    |> Enum.filter(&(&1.type == :platform_alerts_changed))
  end

  test "a notice that cannot be written rolls back the save and its log event", ctx do
    assert {:error, error} =
             Security.save_platform_alert_settings(
               %{disabled_kinds: ["api_key_rate_limited"]},
               actor: ctx.platform
             )

    assert Exception.message(error) =~ "platform_notice refused by the test"

    assert Alerts.platform_disabled_kinds() == []
    assert Alerts.platform_enabled?(:api_key_rate_limited)
    assert platform_alerts_changed() == []
  end

  test "turning a kind back on writes no notice, so it still saves", ctx do
    # Seeded off without a notice: the trigger refuses every one.
    Ash.Seed.seed!(Security.PlatformAlertSettings, %{disabled_kinds: ["api_key_rate_limited"]})

    assert {:ok, row} =
             Security.save_platform_alert_settings(%{disabled_kinds: []}, actor: ctx.platform)

    assert row.disabled_kinds == []
    assert [_event] = platform_alerts_changed()
  end

  test "the page says the save failed and the kind stays on", %{conn: conn} = ctx do
    {:ok, lv, _html} = conn |> log_in(ctx.platform) |> live(~p"/editor/security-alerts")

    html =
      lv
      |> form("#platform-alerts-form", platform_alerts: %{"api_key_rate_limited" => "false"})
      |> render_submit()

    assert html =~ "The platform alert settings could not be saved."
    refute html =~ "Platform alert settings saved."

    assert has_element?(
             lv,
             "#platform-alert-kind-api_key_rate_limited input[type=checkbox][checked]"
           )

    assert Alerts.platform_disabled_kinds() == []
    assert platform_alerts_changed() == []
  end

  defp log_in(conn, user) do
    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
