defmodule KilnCMS.MailTest do
  @moduledoc """
  Coverage for the outbound-mail pipeline (`KilnCMS.Mail`): per-recipient
  queueing, serialisation round-trip through Oban args, and the SMTP failure
  classification that decides whether a delivery job cancels (hard bounce) or
  retries (greylisting, network trouble, the relay refusing us), and whether a
  hard bounce suppresses the recipient.
  """
  use KilnCMS.DataCase, async: true
  # `except: from/2` — DataCase already imports Ecto.Query.from/2.
  import Swoosh.Email, except: [from: 2]
  import Swoosh.TestAssertions

  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker

  # Failing Swoosh adapters injected via the config override of
  # `deliver_for_worker/2`, mimicking the error shapes gen_smtp produces.
  defmodule PermanentFailureAdapter do
    use Swoosh.Adapter

    # The 5xx text echoes the recipient address, as real MTAs routinely do —
    # so the redaction path is exercised. A RCPT TO reject arrives under
    # `:send` (the mail transaction), never `:no_more_hosts` (the session).
    def deliver(_email, _config),
      do:
        {:error,
         {:send,
          {:permanent_failure, ~c"mx.example.com",
           "550 5.1.1 <one@example.com>: Recipient address rejected"}}}
  end

  # Answers whatever gen_smtp error term the test passes as `error:`, for the
  # classification tables below.
  defmodule ErrorAdapter do
    use Swoosh.Adapter

    def deliver(_email, config), do: {:error, Keyword.fetch!(config, :error)}
  end

  defmodule TransientFailureAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:retries_exceeded, {:temporary_failure, ~c"mx.example.com", "451 4.7.1 greylisted"}}}
  end

  # Relay/MX unreachable: gen_smtp reports DNS/TCP trouble as `:network_failure`
  # wrapping a posix atom — a *connection-class* transient (vs the 4xx above).
  defmodule ConnectionFailureAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error, {:retries_exceeded, {:network_failure, ~c"mx.example.com", {:error, :nxdomain}}}}
  end

  # `apply/3` hides the call from the compile-time type checker, which would
  # otherwise flag these calls for always hitting a raise — that being the
  # point of the invalid-input test.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp enqueue_opaquely!(email), do: apply(Mail, :enqueue!, [email])

  defp email do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@example.com"})
    |> to("one@example.com")
    |> subject("Hello")
    |> html_body("<p>Hi</p>")
    |> text_body("Hi")
  end

  describe "enqueue!/1" do
    test "queues one job per recipient and delivery round-trips the email" do
      :ok =
        email()
        |> put_to([{"Two", "two@example.com"}, "one@example.com"])
        |> reply_to("replies@example.com")
        |> Mail.enqueue!()

      drain_oban()

      assert_email_sent(fn sent ->
        sent.to == [{"Two", "two@example.com"}] and sent.subject == "Hello" and
          sent.html_body == "<p>Hi</p>" and sent.text_body == "Hi" and
          sent.reply_to == {"", "replies@example.com"} and
          sent.from == {"KilnCMS", "cms@example.com"} and
          sent.headers["Message-ID"] =~ ~r/^<.+@example\.com>$/
      end)

      assert_email_sent(fn sent -> sent.to == [{"", "one@example.com"}] end)
    end

    test "rejects attachments, cc/bcc, and empty recipients" do
      attachment = %Swoosh.Attachment{filename: "x.txt", content_type: "text/plain", data: "x"}

      assert_raise ArgumentError, ~r/attachments/, fn ->
        email() |> Map.put(:attachments, [attachment]) |> enqueue_opaquely!()
      end

      assert_raise ArgumentError, ~r/cc\/bcc/, fn ->
        email() |> Map.put(:cc, [{"", "cc@example.com"}]) |> enqueue_opaquely!()
      end

      assert_raise ArgumentError, ~r/provider_options/, fn ->
        email() |> Map.put(:provider_options, %{foo: :bar}) |> enqueue_opaquely!()
      end

      assert_raise ArgumentError, ~r/no recipients/, fn ->
        email() |> Map.put(:to, []) |> enqueue_opaquely!()
      end
    end

    test "rejects a malformed recipient address instead of queuing an undeliverable job" do
      # Without the guard, a no-@ address becomes the SMTP relay in DirectMX
      # and retries for ~16h as a "transient" DNS failure.
      for bad <- ["userexample.com", "user@", "@example.com", "a@b@c"] do
        assert_raise ArgumentError, ~r/invalid recipient/, fn ->
          email() |> put_to([{"", bad}]) |> enqueue_opaquely!()
        end
      end
    end
  end

  describe "ensure_message_id/2" do
    test "stamps a From-domain Message-ID and is idempotent" do
      stamped = Mail.ensure_message_id(email())
      id = stamped.headers["Message-ID"]
      assert id =~ ~r/^<.+@example\.com>$/
      # Idempotent: a second call keeps the existing ID.
      assert Mail.ensure_message_id(stamped).headers["Message-ID"] == id
    end

    test "a token makes the ID stable across rebuilds (retry safety)" do
      one = Mail.ensure_message_id(email(), "workflow-42").headers["Message-ID"]
      two = Mail.ensure_message_id(email(), "workflow-42").headers["Message-ID"]
      assert one == two
      assert one == "<workflow-42@example.com>"
    end

    test "falls back to the configured sending domain when From is unset" do
      # :email_from default in test is noreply@kilncms.dev (config/config.exs).
      no_from = new() |> to("a@b.test") |> subject("x")
      assert Mail.ensure_message_id(no_from).headers["Message-ID"] =~ ~r/@kilncms\.dev>$/
    end

    test "lowercases the domain (single source of truth via domain_of/1)" do
      mixed = new() |> Swoosh.Email.from({"K", "Cms@Example.COM"}) |> to("a@b.test")
      assert Mail.ensure_message_id(mixed).headers["Message-ID"] =~ ~r/@example\.com>$/
    end
  end

  test "domain_of/1 returns the lowercased domain part" do
    assert Mail.domain_of("User@Example.COM") == "example.com"
    assert Mail.domain_of("a@b.test") == "b.test"
  end

  describe "deliver_for_worker/2" do
    test "returns :ok on successful delivery" do
      assert :ok = Mail.deliver_for_worker(email())
      assert_email_sent()
    end

    @tag :capture_log
    test "cancels on a permanent (5xx) failure and emits a bounce event" do
      ref = make_ref()
      handler_id = "mail-bounce-#{inspect(ref)}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:kiln_cms, :mail, :bounced],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:cancel, reason} =
               Mail.deliver_for_worker(email(), adapter: PermanentFailureAdapter)

      assert reason =~ "permanent delivery failure"
      # The address the 5xx echoed is scrubbed from the cancel reason...
      refute reason =~ "one@example.com"
      assert reason =~ "[address redacted]"

      assert_receive {^ref, %{count: 1}, metadata}
      # ...and from the telemetry metadata (domains only; may reach exporters).
      assert metadata.recipient_domains == ["example.com"]
      refute metadata.reason =~ "one@example.com"
      assert metadata.reason =~ "[address redacted]"
      # The SMTP status is preserved so the reason stays useful for debugging.
      assert metadata.reason =~ "550"
    end

    test "raises for transient failures so Oban retries" do
      assert_raise Mail.TransientDeliveryError, ~r/transient delivery failure/, fn ->
        Mail.deliver_for_worker(email(), adapter: TransientFailureAdapter)
      end
    end

    @tag :capture_log
    test "a connection-class failure (relay unreachable) still raises so Oban retries" do
      # Alerting is asserted in KilnCMS.Mail.RelayAlertTest; here we only pin
      # that classification doesn't change the retry contract.
      assert_raise Mail.TransientDeliveryError, ~r/transient delivery failure/, fn ->
        Mail.deliver_for_worker(email(), adapter: ConnectionFailureAdapter)
      end
    end

    @tag :capture_log
    test "a permanent failure suppresses the recipient so future sends skip it" do
      refute Mail.suppressed?("one@example.com")

      assert {:cancel, _reason} =
               Mail.deliver_for_worker(email(), adapter: PermanentFailureAdapter)

      assert Mail.suppressed?("one@example.com")
      # Case-insensitive.
      assert Mail.suppressed?("One@Example.com")

      # A later enqueue to the suppressed address queues nothing...
      :ok = email() |> put_to([{"", "one@example.com"}]) |> Mail.enqueue!()
      drain_oban()
      refute_email_sent()

      # ...while other recipients are unaffected.
      :ok = email() |> put_to([{"", "live@example.com"}]) |> Mail.enqueue!()
      drain_oban()
      assert_email_sent(fn sent -> sent.to == [{"", "live@example.com"}] end)
    end
  end

  describe "deliver_for_worker/2 on a permanent failure of our own side" do
    # The relay refused the session or the sender, not the recipient. gen_smtp
    # still calls these `:permanent_failure`, so each used to suppress every
    # address it was sending to — a rotated SMTP_PASSWORD would have silently
    # stopped everyone's mail, password resets included, until an admin removed
    # each address by hand.
    @relay_refusals [
      # AUTH rejected — the rotated-password case (gen_smtp_client.erl, try_AUTH).
      {:no_more_hosts, {:permanent_failure, ~c"relay", :auth_failed}},
      # STARTTLS with no TLS stack running.
      {:no_more_hosts, {:permanent_failure, ~c"relay", :ssl_not_started}},
      # A 5xx banner or EHLO, before any address is sent — even one whose
      # status would name a recipient, since none has been given yet.
      {:no_more_hosts,
       {:permanent_failure, ~c"relay", "554 5.7.1 Client host [203.0.113.9] blocked"}},
      {:no_more_hosts, {:permanent_failure, ~c"relay", "550 5.1.1 unexpected"}},
      # MAIL FROM refused: the sender isn't ours to use, or its domain is bad.
      {:send,
       {:permanent_failure, ~c"relay",
        "553 5.7.1 <cms@example.com>: Sender address rejected: not owned by user"}},
      {:send, {:permanent_failure, ~c"relay", "550 5.1.8 <cms@example.com>: domain not found"}},
      # A relay wanting AUTH, with and without an enhanced status.
      {:send, {:permanent_failure, ~c"relay", "530 5.7.0 Authentication required"}},
      {:send, {:permanent_failure, ~c"relay", "535 Authentication credentials invalid"}},
      # Unauthenticated relaying to the recipient's domain.
      {:send,
       {:permanent_failure, ~c"relay", "554 5.7.1 <one@example.com>: Relay access denied"}},
      # The receiver failing our DKIM/SPF/DMARC.
      {:send,
       {:permanent_failure, ~c"mx.example.com",
        "550-5.7.26 Unauthenticated email is not accepted due to domain's DMARC policy"}}
    ]

    @tag :capture_log
    test "retries, and suppresses nobody" do
      for {reason, n} <- Enum.with_index(@relay_refusals) do
        address = "refused-#{n}@example.com"

        assert_raise Mail.TransientDeliveryError,
                     ~r/relay refused delivery/,
                     fn -> deliver_failing(address, reason) end

        refute Mail.suppressed?(address), "#{inspect(reason)} suppressed the recipient"
      end
    end

    @tag :capture_log
    test "a rotated relay password leaves the address mailable once it is fixed" do
      auth_failed = {:no_more_hosts, {:permanent_failure, ~c"relay", :auth_failed}}

      assert_raise Mail.TransientDeliveryError, fn ->
        deliver_failing("reset-me@example.com", auth_failed)
      end

      :ok = email() |> put_to([{"", "reset-me@example.com"}]) |> Mail.enqueue!()
      drain_oban()
      assert_email_sent(fn sent -> sent.to == [{"", "reset-me@example.com"}] end)
    end
  end

  describe "deliver_for_worker/2 on a permanent reject of the message" do
    @recipient_rejects [
      "550 5.1.1 <one@example.com>: Recipient address rejected: User unknown",
      # Gmail's multiline form.
      "550-5.1.1 The email account that you tried to reach does not exist.\r\n" <>
        "550 5.1.1 https://support.google.com/mail/?p=NoSuchUser",
      "550 5.1.2 Host unknown",
      "550 5.1.10 Recipient address has null MX",
      "550 5.2.1 Mailbox disabled"
    ]

    # 5xx that says nothing about whose fault it is.
    @unattributed_rejects [
      "554 5.7.1 Message rejected as spam",
      "552 5.3.4 Message size exceeds fixed limit",
      # Mailbox full clears on its own; it is no reason to stop mailing someone.
      "552 5.2.2 Mailbox full",
      # No enhanced status at all.
      "550 Requested action not taken",
      # A status-shaped token further into the text is not the status: RFC
      # 2034 puts it straight after the reply code or nowhere.
      "550 Blocked, see https://blocklist.example/5.1.1 for why"
    ]

    @tag :capture_log
    test "a reject naming the recipient cancels and suppresses it" do
      for {reply, n} <- Enum.with_index(@recipient_rejects) do
        address = "dead-#{n}@example.com"
        reason = {:send, {:permanent_failure, ~c"mx.example.com", reply}}

        assert {:cancel, "permanent delivery failure: " <> _} = deliver_failing(address, reason)
        assert Mail.suppressed?(address), "#{inspect(reply)} did not suppress the recipient"
      end
    end

    @tag :capture_log
    test "a reject that doesn't name the recipient cancels without suppressing it" do
      for {reply, n} <- Enum.with_index(@unattributed_rejects) do
        address = "unsure-#{n}@example.com"
        reason = {:send, {:permanent_failure, ~c"mx.example.com", reply}}

        assert {:cancel, "permanent delivery failure: " <> _} = deliver_failing(address, reason)
        refute Mail.suppressed?(address), "#{inspect(reply)} suppressed the recipient"
      end
    end
  end

  describe "suppression list" do
    test "suppress is idempotent (upsert) and refreshes the reason" do
      admin = admin_user()

      {:ok, first} =
        Mail.suppress_recipient(%{email: "dupe@example.com", reason: "550 one"}, actor: admin)

      {:ok, second} =
        Mail.suppress_recipient(%{email: "dupe@example.com", reason: "550 two"}, actor: admin)

      assert first.id == second.id
      assert second.reason == "550 two"
      assert [_only] = Mail.list_suppressed_recipients!(actor: admin)
    end

    test "unsuppress lets an address receive mail again" do
      admin = admin_user()
      {:ok, record} = Mail.suppress_recipient(%{email: "back@example.com"}, actor: admin)
      assert Mail.suppressed?("back@example.com")

      :ok = Mail.unsuppress_recipient(record, actor: admin)
      refute Mail.suppressed?("back@example.com")
    end

    test "managing suppressions is admin-only" do
      admin = admin_user()
      editor = user(:editor)
      {:ok, _} = Mail.suppress_recipient(%{email: "hidden@example.com"}, actor: admin)

      # Writes are forbidden outright...
      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.suppress_recipient(%{email: "x@example.com"}, actor: editor)

      # ...and the read policy filters non-admins to nothing (never leaks the list).
      assert {:ok, []} = Mail.list_suppressed_recipients(actor: editor)
      assert [_one] = Mail.list_suppressed_recipients!(actor: admin)
    end
  end

  test "recent_delivery_failures summarizes failed mail jobs with domain only (no address)" do
    # Insert a cancelled mail job directly; a unique domain scopes the assertion
    # against the shared oban_jobs table.
    domain = "boom-#{System.unique_integer([:positive])}.test"

    {:ok, _job} =
      KilnCMS.Repo.insert(%Oban.Job{
        worker: "KilnCMS.Mail.DeliveryWorker",
        queue: "mail",
        state: "cancelled",
        args: %{"to" => ["", "dead@#{domain}"], "subject" => "x"},
        errors: [%{"error" => "permanent delivery failure: 550 [address redacted]"}],
        attempted_at: DateTime.utc_now()
      })

    failure = Enum.find(Mail.recent_delivery_failures(), &(&1.domain == domain))

    assert failure.state == "cancelled"
    assert failure.reason =~ "550"
    refute failure.reason =~ "dead@"
  end

  test "backoff follows the greylist-aware schedule and plateaus" do
    schedule = Enum.map(1..8, &DeliveryWorker.backoff(%Oban.Job{attempt: &1}))
    assert schedule == [60, 300, 900, 3600, 7200, 14_400, 28_800, 28_800]
  end

  test "both mail workers cap each attempt at attempt_timeout/0" do
    assert Mail.attempt_timeout() == :timer.seconds(60)
    assert DeliveryWorker.timeout(%Oban.Job{}) == Mail.attempt_timeout()

    assert KilnCMS.Notifications.WorkflowMailWorker.timeout(%Oban.Job{}) ==
             Mail.attempt_timeout()
  end

  defp deliver_failing(address, reason) do
    email()
    |> put_to([{"", address}])
    |> Mail.deliver_for_worker(adapter: ErrorAdapter, error: reason)
  end

  defp admin_user, do: user(:admin)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mail-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end
end
