defmodule KilnCMS.Mail.RelayAlertTest do
  @moduledoc """
  The aggregated "relay unreachable" alert: it fires once on a connection-class
  delivery failure, stays quiet for the cooldown, and — crucially — is *not*
  tripped by ordinary greylisting. And its "relay refused" twin, for a relay
  that answers but refuses our AUTH, TLS or sender.

  `async: false`: the alert's cooldown bucket and the telemetry handler are
  process-global, so these run in isolation to keep the single-fire and
  refute-fire assertions deterministic (a concurrent test firing the event
  would bleed into the shared handler).
  """
  use KilnCMS.DataCase, async: false

  import Swoosh.Email, except: [from: 2]

  alias KilnCMS.Mail
  alias KilnCMS.Mail.RelayAlert

  # Connection-class (relay/MX unreachable) vs greylisting (SMTP 4xx) — the two
  # transient shapes gen_smtp produces, mirroring KilnCMS.MailTest's adapters.
  defmodule ConnectionFailureAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error, {:retries_exceeded, {:network_failure, ~c"mx.example.com", {:error, :nxdomain}}}}
  end

  defmodule GreylistAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:retries_exceeded, {:temporary_failure, ~c"mx.example.com", "451 4.7.1 greylisted"}}}
  end

  # The rotated-password case: gen_smtp's AUTH failure is a `:permanent_failure`.
  defmodule AuthFailedAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do: {:error, {:no_more_hosts, {:permanent_failure, ~c"relay", :auth_failed}}}
  end

  setup do
    # Clear the cooldown so each test starts from a fireable state.
    RelayAlert.reset()

    ref = make_ref()
    handler_id = "relay-alert-#{inspect(ref)}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [[:kiln_cms, :mail, :relay_unreachable], [:kiln_cms, :mail, :relay_refused]],
      fn [:kiln_cms, :mail, kind], measurements, metadata, _cfg ->
        send(test_pid, {ref, kind, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{ref: ref}
  end

  defp email do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@example.com"})
    |> to("one@example.com")
    |> subject("Hello")
    |> html_body("<p>Hi</p>")
    |> text_body("Hi")
  end

  @tag :capture_log
  test "notify/1 fires one alert with the recipient domain (no address)", %{ref: ref} do
    assert :ok = RelayAlert.notify("example.com")

    assert_receive {^ref, :relay_unreachable, %{count: 1}, %{domain: "example.com"}}
  end

  @tag :capture_log
  test "cooldown suppresses a second alert within the window", %{ref: ref} do
    assert :ok = RelayAlert.notify("example.com")
    assert_receive {^ref, :relay_unreachable, %{count: 1}, _metadata}

    # Second call inside the window is swallowed — no second telemetry event.
    assert :ok = RelayAlert.notify("other.example")
    refute_receive {^ref, _kind, _measurements, _metadata}
  end

  @tag :capture_log
  test "a connection-class delivery failure raises the alert", %{ref: ref} do
    assert_raise Mail.TransientDeliveryError, fn ->
      Mail.deliver_for_worker(email(), adapter: ConnectionFailureAdapter)
    end

    assert_receive {^ref, :relay_unreachable, %{count: 1}, %{domain: "example.com"}}
  end

  @tag :capture_log
  test "greylisting (SMTP 4xx) retries quietly without alerting", %{ref: ref} do
    assert_raise Mail.TransientDeliveryError, fn ->
      Mail.deliver_for_worker(email(), adapter: GreylistAdapter)
    end

    refute_receive {^ref, _kind, _measurements, _metadata}
  end

  @tag :capture_log
  test "a relay refusing our AUTH raises the refused alert, with the reason", %{ref: ref} do
    assert_raise Mail.TransientDeliveryError, fn ->
      Mail.deliver_for_worker(email(), adapter: AuthFailedAdapter)
    end

    assert_receive {^ref, :relay_refused, %{count: 1}, metadata}
    assert metadata.domain == "example.com"
    assert metadata.reason =~ "auth_failed"
    # It is not an outage alert.
    refute_receive {^ref, :relay_unreachable, _measurements, _metadata}
  end

  @tag :capture_log
  test "a site's own relay refusing us neither alerts nor spends the operator's cooldown",
       %{ref: ref} do
    org = KilnCMS.OrgFixtures.org("relay-alert-site")

    KilnCMS.CMS.save_site_mail_relay!(
      %{host: "smtp.example.com", from_email: "news@site.example"},
      tenant: org,
      authorize?: false
    )

    # The site's relay refusing the site's password is the site's to fix.
    assert_raise Mail.TransientDeliveryError, fn ->
      Mail.deliver_for_worker(email(), org_id: org.id, adapter: AuthFailedAdapter)
    end

    refute_receive {^ref, _kind, _measurements, _metadata}

    # And the operator's relay failing right after still alerts: the site's
    # refusal didn't take the one alert the cooldown allows.
    assert_raise Mail.TransientDeliveryError, fn ->
      Mail.deliver_for_worker(email(), adapter: AuthFailedAdapter)
    end

    assert_receive {^ref, :relay_refused, %{count: 1}, _metadata}
  end

  @tag :capture_log
  test "refused and unreachable keep separate cooldowns", %{ref: ref} do
    assert :ok = RelayAlert.notify_refused("example.com", "auth_failed")
    assert_receive {^ref, :relay_refused, _measurements, _metadata}

    # A refusal already alerted doesn't swallow an outage...
    assert :ok = RelayAlert.notify("example.com")
    assert_receive {^ref, :relay_unreachable, _measurements, _metadata}

    # ...but a second refusal inside the window is quiet.
    assert :ok = RelayAlert.notify_refused("other.example", "auth_failed")
    refute_receive {^ref, _kind, _measurements, _metadata}
  end
end
