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

    def deliver(_email, _config),
      do:
        {:error,
         {:no_more_hosts, {:permanent_failure, ~c"mx.example.com", "550 5.1.1 no such user"}}}
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

      assert_raise ArgumentError, ~r/no recipients/, fn ->
        email() |> Map.put(:to, []) |> enqueue_opaquely!()
      end
    end
  end

  describe "deliver_for_worker/2" do
    test "returns :ok on successful delivery" do
      assert :ok = Mail.deliver_for_worker(email())
      assert_email_sent()
    end

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

      assert_receive {^ref, %{count: 1}, metadata}
      # Domains only — never full addresses (telemetry may reach exporters).
      assert metadata.recipient_domains == ["example.com"]
      refute metadata.reason =~ "one@"
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
