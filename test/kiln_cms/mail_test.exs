defmodule KilnCMS.MailTest do
  @moduledoc """
  Coverage for the outbound-mail pipeline (`KilnCMS.Mail`): per-recipient
  queueing, serialisation round-trip through Oban args, and the SMTP failure
  classification that decides whether a delivery job cancels (hard bounce) or
  retries (greylisting, network trouble).
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
    # so the redaction path is exercised.
    def deliver(_email, _config),
      do:
        {:error,
         {:no_more_hosts,
          {:permanent_failure, ~c"mx.example.com",
           "550 5.1.1 <one@example.com>: Recipient address rejected"}}}
  end

  defmodule TransientFailureAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:retries_exceeded, {:temporary_failure, ~c"mx.example.com", "451 4.7.1 greylisted"}}}
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
  end

  test "backoff follows the greylist-aware schedule and plateaus" do
    schedule = Enum.map(1..8, &DeliveryWorker.backoff(%Oban.Job{attempt: &1}))
    assert schedule == [60, 300, 900, 3600, 7200, 14_400, 28_800, 28_800]
  end
end
