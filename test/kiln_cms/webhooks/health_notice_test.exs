defmodule KilnCMS.Webhooks.HealthNoticeTest do
  @moduledoc """
  Telling a site's admins that a webhook is not getting through
  (`KilnCMS.Webhooks.HealthNotice`): a notice and an email on the first
  exhausted delivery in a row, and again when the endpoint is auto-disabled.
  The webhooks page reading them is in `KilnCMSWeb.WebhookLiveTest`.
  """
  # async: false — tweaks the global auto-disable threshold via app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link
  alias KilnCMS.Webhooks
  alias KilnCMS.Webhooks.HealthNotice
  alias KilnCMSWeb.NotificationText

  @moduletag :capture_log

  # An incoming-webhook style URL: the token in its path is the credential.
  @hook_url "https://example.test/hooks/T0SECRET-token-Zq9x"
  @masked_url "https://example.test/…/Zq9x"
  @secret_segment "T0SECRET-token"

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Webhooks, original) end)
    :ok
  end

  defp put_webhook_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])
    Application.put_env(:kiln_cms, KilnCMS.Webhooks, Keyword.merge(base, overrides))
  end

  defp admin(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "whhealth-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        },
        attrs
      )
    )
  end

  defp endpoint!(actor),
    do: CMS.create_webhook_endpoint!(%{url: @hook_url, events: ["page.published"]}, actor: actor)

  defp stub_status(status) do
    Req.Test.stub(KilnCMS.Webhooks, fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
  end

  defp fail_one_delivery do
    Webhooks.dispatch("page.published", %{})
    Oban.drain_queue(queue: :webhooks, with_scheduled: true, with_recursion: true)
  end

  defp notices(user, event) do
    user
    |> Notifications.recent(KilnCMS.Accounts.default_org_id(), 50)
    |> Enum.filter(&(&1.event == event))
  end

  # The mails delivered since the last call: the mail queue is drained and
  # the test adapter's messages taken from the mailbox.
  defp mails_to(user) do
    KilnCMS.DataCase.drain_oban()
    Enum.filter(collect([]), &(to_address(&1) == to_string(user.email)))
  end

  defp collect(acc) do
    receive do
      {:email, email} -> collect([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp to_address(%{to: [{_name, address} | _]}), do: address

  # The record `:record_delivery_failure` returns when it switched the
  # endpoint off.
  defp switched_off(endpoint), do: Map.put(endpoint, :__metadata__, %{auto_disabled: true})

  # Decided on the record the failure action returned (#2737), not on the
  # worker's copy from before its POST.
  describe "event_for/1" do
    test "the first failure in a row of an active endpoint is :webhook_failing" do
      assert HealthNotice.event_for(%{active: true, consecutive_failures: 1}) == :webhook_failing
    end

    test "the failure that switched it off is :webhook_disabled" do
      assert HealthNotice.event_for(switched_off(%{active: false, consecutive_failures: 10})) ==
               :webhook_disabled

      # A threshold of one: the first failure is also the last.
      assert HealthNotice.event_for(switched_off(%{active: false, consecutive_failures: 1})) ==
               :webhook_disabled
    end

    test "the failures in between are not news" do
      assert HealthNotice.event_for(%{active: true, consecutive_failures: 2}) == nil

      # Already off when this failure was recorded: another one switched it off.
      assert HealthNotice.event_for(%{
               active: false,
               consecutive_failures: 10,
               __metadata__: %{auto_disabled: false}
             }) == nil
    end
  end

  describe "through the delivery pipeline" do
    test "the first exhausted delivery tells the site's admins, once" do
      stub_status(500)
      put_webhook_env(auto_disable_after: 3)
      admin = admin()
      endpoint = endpoint!(admin)

      fail_one_delivery()

      assert [notice] = notices(admin, :webhook_failing)
      assert notice.content_type == "webhook_endpoint"
      assert notice.content_id == endpoint.id
      assert notice.title == @masked_url
      refute notice.title =~ @secret_segment
      assert notice.excerpt =~ "failed after every retry"
      assert NotificationText.headline(notice) == "A webhook is failing"
      assert Link.editor_path(notice) == "/editor/webhooks"

      assert [mail] = mails_to(admin)
      assert mail.subject =~ "A webhook is failing on"
      assert mail.html_body =~ @masked_url
      assert mail.html_body =~ "/editor/webhooks"
      refute mail.html_body =~ @secret_segment

      # The second failure in a row is not news.
      fail_one_delivery()
      assert [_one] = notices(admin, :webhook_failing)
      assert mails_to(admin) == []
      assert notices(admin, :webhook_disabled) == []
    end

    test "auto-disabling the endpoint tells the site's admins" do
      stub_status(500)
      put_webhook_env(auto_disable_after: 2)
      admin = admin()
      endpoint = endpoint!(admin)

      fail_one_delivery()
      fail_one_delivery()

      refute CMS.get_webhook_endpoint!(endpoint.id, authorize?: false).active

      assert [notice] = notices(admin, :webhook_disabled)
      assert notice.content_id == endpoint.id
      assert notice.excerpt =~ "Switched off after 2 failed deliveries in a row"
      assert NotificationText.headline(notice) == "A webhook was switched off"

      subjects = Enum.map(mails_to(admin), & &1.subject)
      assert Enum.any?(subjects, &(&1 =~ "A webhook was switched off on"))
    end

    test "a success between failures makes the next failure news again" do
      put_webhook_env(auto_disable_after: 5)
      admin = admin()
      endpoint!(admin)

      stub_status(500)
      fail_one_delivery()

      # The admin read it; the receiver recovered, then failed again.
      [notice] = notices(admin, :webhook_failing)

      {:ok, _} =
        Notifications.mark_read_about(admin, notice.org_id, :webhook_failing, notice.content_id)

      stub_status(200)
      fail_one_delivery()
      stub_status(500)
      fail_one_delivery()

      assert length(notices(admin, :webhook_failing)) == 2
    end
  end

  test "a muted admin still gets the notice, but no email" do
    admin = admin(%{notify_on_webhook_failure: false})
    endpoint = endpoint!(admin)

    :ok = HealthNotice.surface(%{endpoint | consecutive_failures: 1})

    assert [_notice] = notices(admin, :webhook_failing)
    assert mails_to(admin) == []
  end

  test "an erased admin hears nothing" do
    admin = admin()
    endpoint = endpoint!(admin)
    erased = admin(%{anonymized_at: DateTime.utc_now()})

    :ok =
      HealthNotice.surface(switched_off(%{endpoint | active: false, consecutive_failures: 10}))

    assert [_notice] = notices(admin, :webhook_disabled)
    refute erased.id in Enum.map(HealthNotice.recipients(endpoint.org_id), & &1.id)
  end
end
