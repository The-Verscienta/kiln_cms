defmodule KilnCMS.Newsletter.MailWorkerExhaustionTest do
  @moduledoc """
  #2755: every recipient ends in the campaign's tally. A recipient whose last
  attempt still fails, by a raise, an `{:error, _}` or running past its
  deadline, is counted failed once and the job cancels, rather than Oban
  discarding it with no counter moved. Earlier attempts retry uncounted, and
  an outcome the delivery already counted is not counted again.
  """
  # async: false — the tests swap the global mailer adapter and this worker's
  # app config with `Application.put_env`, and publishing a post drains Oban
  # with the shared sandbox connection.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Mail.TransientDeliveryError
  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.MailWorker
  alias KilnCMS.Newsletter.NewsletterSend
  alias KilnCMS.Newsletter.SendWorker

  @max_attempts 8

  # Greylists any address on the `dead-mx` domain; everything else goes to
  # the test mailbox as usual.
  defmodule DeadDomainAdapter do
    use Swoosh.Adapter

    def deliver(email, config) do
      if Enum.any?(email.to, fn {_name, address} ->
           String.ends_with?(address, "@dead-mx.test")
         end),
         do:
           {:error,
            {:retries_exceeded,
             {:temporary_failure, ~c"mx.dead-mx.test", "451 4.7.1 try again later"}}},
         else: Swoosh.Adapters.Test.deliver(email, config)
    end
  end

  defmodule PermanentRejectAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:retries_exceeded,
          {:permanent_failure, ~c"mx.example.com", "550 5.1.1 mailbox unavailable"}}}
  end

  # A relay that accepts the connection and never answers.
  defmodule TarpitAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config), do: Process.sleep(:infinity)
  end

  setup do
    mailer = Application.get_env(:kiln_cms, KilnCMS.Mailer)
    worker = Application.get_env(:kiln_cms, MailWorker)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Mailer, mailer)

      if worker,
        do: Application.put_env(:kiln_cms, MailWorker, worker),
        else: Application.delete_env(:kiln_cms, MailWorker)
    end)

    :ok
  end

  defp use_adapter(adapter), do: Application.put_env(:kiln_cms, KilnCMS.Mailer, adapter: adapter)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "nl2755-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "nl2755-#{System.unique_integer([:positive])}"

  defp subscriber(actor, domain) do
    %{email: "nl2755-#{System.unique_integer([:positive])}@#{domain}"}
    |> Newsletter.subscribe!(actor: actor)
    |> Newsletter.confirm_subscriber!(actor: actor)
  end

  defp published_post(actor) do
    post = CMS.create_post!(%{title: "NL2755 #{slug()}", slug: slug()}, actor: actor)
    published = CMS.publish_post!(post, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    published
  end

  # A queued campaign for `domains`, one confirmed subscriber each.
  defp campaign(domains) do
    admin = admin()
    subs = Enum.map(domains, &subscriber(admin, &1))
    post = published_post(admin)
    {:ok, send} = Newsletter.send_as_newsletter(post, actor: admin)
    %{admin: admin, send: send, subs: subs}
  end

  defp mail_args(send, subscriber_id),
    do: %{
      "newsletter_send_id" => send.id,
      "subscriber_id" => subscriber_id,
      "org_id" => send.org_id
    }

  defp run(send, subscriber_id, attempt),
    do: perform_job(MailWorker, mail_args(send, subscriber_id), attempt: attempt)

  defp reload(send), do: Newsletter.get_send!(send.id, authorize?: false, tenant: send.org_id)

  describe "the last attempt" do
    test "a transient failure that raises is counted failed once, and cancels" do
      %{send: send, subs: [sub]} = campaign(["dead-mx.test"])
      use_adapter(DeadDomainAdapter)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = run(send, sub.id, @max_attempts)
          assert reason =~ "gave up after #{@max_attempts} attempts"
          assert reason =~ "transient delivery failure"
        end)

      assert log =~ "counted as failed"

      send = reload(send)
      assert send.failed_count == 1
      assert send.sent_count == 0
    end

    test "an error return is counted failed once, and cancels" do
      %{send: send} = campaign(["example.com"])

      capture_log(fn ->
        assert {:cancel, reason} = run(send, "not-a-uuid", @max_attempts)
        assert reason =~ "gave up after #{@max_attempts} attempts"
      end)

      assert reload(send).failed_count == 1
    end

    test "running past its deadline is counted failed once, and cancels" do
      %{send: send, subs: [sub]} = campaign(["example.com"])
      use_adapter(TarpitAdapter)
      Application.put_env(:kiln_cms, MailWorker, final_attempt_ms: 200)

      capture_log(fn ->
        assert {:cancel, reason} = run(send, sub.id, @max_attempts)
        assert reason =~ "timed out after 200 ms"
      end)

      assert reload(send).failed_count == 1
    end

    test "Oban's ceiling sits above the attempt's own deadline" do
      Application.put_env(:kiln_cms, MailWorker, final_attempt_ms: 200)

      last = %Oban.Job{attempt: @max_attempts, max_attempts: @max_attempts}
      earlier = %Oban.Job{attempt: @max_attempts - 1, max_attempts: @max_attempts}

      assert MailWorker.timeout(last) > 200
      assert MailWorker.timeout(earlier) == KilnCMS.Mail.attempt_timeout()
    end

    test "a permanent reject the delivery already counted is not counted again" do
      %{send: send, subs: [sub]} = campaign(["example.com"])
      use_adapter(PermanentRejectAdapter)

      capture_log(fn ->
        assert {:cancel, reason} = run(send, sub.id, @max_attempts)
        assert reason =~ "permanent delivery failure"
      end)

      assert reload(send).failed_count == 1
    end

    test "a subscriber who left since the fan-out is a skip, not a failure" do
      %{admin: admin, send: send, subs: [sub]} = campaign(["example.com"])
      Newsletter.unsubscribe_subscriber!(sub, actor: admin)

      assert {:cancel, reason} = run(send, sub.id, @max_attempts)
      assert reason =~ "not confirmed"
      assert reload(send).failed_count == 0
    end
  end

  describe "an earlier attempt" do
    test "a transient failure raises so Oban retries, and counts nothing" do
      %{send: send, subs: [sub]} = campaign(["dead-mx.test"])
      use_adapter(DeadDomainAdapter)

      for attempt <- 1..(@max_attempts - 1) do
        assert_raise TransientDeliveryError, fn -> run(send, sub.id, attempt) end
      end

      send = reload(send)
      assert send.failed_count == 0
      assert send.sent_count == 0
    end

    test "an error return retries, and counts nothing" do
      %{send: send} = campaign(["example.com"])

      capture_log(fn ->
        assert {:error, _error} = run(send, "not-a-uuid", @max_attempts - 1)
      end)

      assert reload(send).failed_count == 0
    end
  end

  test "a campaign with a dead domain adds up once its retries run out" do
    %{send: send} = campaign(["example.com", "dead-mx.test", "example.org"])
    use_adapter(DeadDomainAdapter)

    assert :ok =
             perform_job(SendWorker, %{"newsletter_send_id" => send.id, "org_id" => send.org_id})

    jobs = all_enqueued(worker: MailWorker)
    assert length(jobs) == 3

    # Each job runs as Oban would: again after every raise, until it returns.
    capture_log(fn ->
      for job <- jobs do
        Enum.reduce_while(1..@max_attempts, nil, fn attempt, _acc ->
          try do
            {:halt, perform_job(MailWorker, job.args, attempt: attempt)}
          rescue
            TransientDeliveryError -> {:cont, :retry}
          end
        end)
      end
    end)

    send = reload(send)
    assert send.total_recipients == 3
    assert send.sent_count == 3 - 1
    assert send.failed_count == 1
    assert send.sent_count + send.failed_count == send.total_recipients
  end

  test "a campaign whose content has no fired :web artifact counts the recipient failed" do
    %{subs: [sub]} = campaign(["example.com"])
    org_id = KilnCMS.Accounts.default_org_id()

    send =
      Ash.Seed.seed!(NewsletterSend, %{
        org_id: org_id,
        content_type: "post",
        content_id: Ash.UUID.generate(),
        subject: "Never fired",
        status: :sent,
        total_recipients: 1
      })

    assert {:cancel, reason} = run(send, sub.id, 1)
    assert reason =~ "no fired :web artifact"
    assert reload(send).failed_count == 1
  end
end
