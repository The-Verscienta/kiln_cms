defmodule KilnCMS.Mail.TokenRedactionTest do
  @moduledoc """
  Sign-in links must not leak out of the mail queue (#1843).

  Every mail that carries a token — account confirmation, password reset,
  magic link, newsletter confirmation — goes through `KilnCMS.Mail.enqueue!/2`.
  Before 1.0 the rendered body sat in the job's args in the clear, and an
  adapter that *crashed* (the stock local adapter in a release with no mail
  server configured exits `:noproc`, quoting the `%Swoosh.Email{}` it was
  pushing) had that whole exit stored as the job's error: readable by admins
  on /editor/mail, and sent to the log and Sentry.

  `async: false`: these tests swap the operator's mailer adapter and the
  `:swoosh` `:local` flag, both application-global.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.Email, except: [from: 2]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.User.Senders.SendMagicLink
  alias KilnCMS.Accounts.User.Senders.SendNewUserConfirmationEmail
  alias KilnCMS.Accounts.User.Senders.SendPasswordResetEmail
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Mail.Scrub

  # Raises with the email in the exception's own message — a `MatchError`
  # quotes the term it failed on, so formatting the exception would leak it.
  defmodule RaisingAdapter do
    use Swoosh.Adapter

    def deliver(email, _config), do: raise(MatchError, term: email)
  end

  # Exits the way `Swoosh.Adapters.Local` does in a release: a
  # `GenServer.call/3` to a mailbox that isn't running, whose exit quotes the
  # call — `{:push, %Swoosh.Email{}}`, body and all.
  defmodule ExitingAdapter do
    use Swoosh.Adapter

    def deliver(email, _config),
      do: GenServer.call({:global, :kiln_mailbox_that_is_not_running}, {:push, email})
  end

  defmodule ThrowingAdapter do
    use Swoosh.Adapter

    def deliver(email, _config), do: throw(email)
  end

  defmodule PermanentFailureAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do: {:error, {:send, {:permanent_failure, ~c"mx.example.com", "550 5.7.1 message refused"}}}
  end

  setup do
    mailer = Application.get_env(:kiln_cms, KilnCMS.Mailer)
    local = Application.fetch_env(:swoosh, :local)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Mailer, mailer)

      case local do
        {:ok, value} -> Application.put_env(:swoosh, :local, value)
        :error -> Application.delete_env(:swoosh, :local)
      end
    end)

    :ok
  end

  defp use_adapter(adapter), do: Application.put_env(:kiln_cms, KilnCMS.Mailer, adapter: adapter)

  defp token, do: "TKN1843" <> Base.encode16(:crypto.strong_rand_bytes(12))

  defp address(tag), do: "redact-#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp user(address) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      role: :viewer
    })
  end

  defp job_for(address) do
    Repo.one!(
      from(j in Oban.Job,
        where:
          j.worker == "KilnCMS.Mail.DeliveryWorker" and
            fragment("?->'to'->>1", j.args) == ^address
      )
    )
  end

  # Every token-bearing mail, queued the way production queues it. Returns the
  # recipient and the secret the mail carries.
  defp queue_token_mail(:password_reset) do
    address = address("reset")
    token = token()
    SendPasswordResetEmail.send(user(address), token, [])
    {address, token}
  end

  defp queue_token_mail(:magic_link) do
    address = address("magic")
    token = token()
    SendMagicLink.send(user(address), token, [])
    {address, token}
  end

  defp queue_token_mail(:confirmation) do
    address = address("confirm")
    token = token()
    SendNewUserConfirmationEmail.send(user(address), token, [])
    {address, token}
  end

  defp queue_token_mail(:newsletter) do
    address = address("news")
    {:ok, subscriber} = KilnCMS.Newsletter.subscribe(%{email: address}, authorize?: false)
    {address, subscriber.confirm_token}
  end

  @senders [:password_reset, :magic_link, :confirmation, :newsletter]

  describe "a crashing adapter" do
    for sender <- @senders, adapter <- [RaisingAdapter, ExitingAdapter, ThrowingAdapter] do
      @tag sender: sender, adapter: adapter
      test "#{sender} mail through #{inspect(adapter)} records no token anywhere",
           %{sender: sender, adapter: adapter} do
        {address, token} = queue_token_mail(sender)
        assert job_for(address), "the #{sender} sender must queue a delivery job"

        use_adapter(adapter)
        previous_level = Logger.level()
        Logger.configure(level: :debug)

        log =
          try do
            capture_log(fn -> Oban.drain_queue(queue: :mail) end)
          after
            Logger.configure(level: previous_level)
          end

        job = job_for(address)
        assert job.state == "retryable"

        # The stored error names what crashed and nothing it carried.
        assert [%{"error" => error}] = job.errors
        assert error =~ "KilnCMS.Mail.MailerCrashError"
        assert error =~ "mailer crashed"
        refute error =~ token
        refute error =~ "Swoosh.Email"

        # Not in the args the job keeps for its retry, nor in any log line —
        # Oban's own logger prints a job's args on every start and stop.
        refute inspect(job.args) =~ token
        refute log =~ token
        refute log =~ "%Swoosh.Email{"
      end
    end
  end

  test "the crash reasons are named, not quoted" do
    for {adapter, expected} <- [
          {RaisingAdapter, "mailer crashed: MatchError"},
          {ExitingAdapter, "mailer crashed: noproc"},
          {ThrowingAdapter, "mailer crashed: throw"}
        ] do
      log =
        capture_log(fn ->
          error =
            assert_raise Mail.MailerCrashError, fn ->
              Mail.deliver_for_worker(email(), adapter: adapter)
            end

          assert error.message == expected
        end)

      refute log =~ "secret-link"
    end
  end

  test "deliver_now/2 answers a crash as an error naming it" do
    use_adapter(ExitingAdapter)

    assert {:error, {:mailer_crashed, "noproc"} = reason} = Mail.deliver_now(email())
    assert Mail.failure_kind(reason) == :crashed
  end

  defp email do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@example.com"})
    |> to("reader@example.com")
    |> subject("Reset")
    |> html_body(~s(<a href="https://cms.example/password-reset/secret-link">reset</a>))
  end

  describe "no outgoing mail server configured" do
    setup do
      # What a release ships: the stock local adapter, and no mailbox for it
      # (`config/prod.exs` sets `local: false`).
      use_adapter(Swoosh.Adapters.Local)
      Application.put_env(:swoosh, :local, false)
      :ok
    end

    test "a queued token mail is held with a reason an admin can act on" do
      {address, token} = queue_token_mail(:password_reset)

      log = capture_log(fn -> Oban.drain_queue(queue: :mail) end)

      job = job_for(address)
      assert job.state == "retryable"
      assert [%{"error" => error}] = job.errors
      assert error =~ "No outgoing mail server is configured — see Mail settings"
      refute error =~ token
      refute log =~ token
    end

    test "deliver_now/2 says so instead of crashing" do
      assert {:error, :mailer_not_configured} = Mail.deliver_now(email())
      assert Mail.failure_kind(:mailer_not_configured) == :not_configured
    end

    test "a site's own relay still delivers its mail" do
      org = KilnCMS.OrgFixtures.org("redact-relay")

      KilnCMS.CMS.save_site_mail_relay!(
        %{
          host: "smtp.example.com",
          port: 587,
          username: "apikey",
          password: "s3cret-pass",
          from_email: "news@site.example"
        },
        tenant: org,
        authorize?: false
      )

      assert :ok = Mail.deliver_for_worker(email(), org_id: org.id)
      assert_received {:site_relay_email, %{from: {_name, "news@site.example"}}, _config}
    end
  end

  describe "a site relay's adapter crashing" do
    test "is caught the same way and never falls back to the operator's relay" do
      org = KilnCMS.OrgFixtures.org("redact-crash")

      KilnCMS.CMS.save_site_mail_relay!(
        %{
          host: "smtp.example.com",
          port: 587,
          username: "apikey",
          password: "s3cret-pass",
          from_email: "news@site.example"
        },
        tenant: org,
        authorize?: false
      )

      capture_log(fn ->
        assert_raise Mail.MailerCrashError, "mailer crashed: noproc", fn ->
          Mail.deliver_for_worker(email(), org_id: org.id, adapter: ExitingAdapter)
        end
      end)

      assert_no_email_sent()
    end
  end

  describe "a finished job forgets its message" do
    test "a delivered job keeps the recipient but not the subject or body" do
      {address, token} = queue_token_mail(:password_reset)
      assert %{"sealed" => _sealed} = job_for(address).args

      Oban.drain_queue(queue: :mail)

      job = job_for(address)
      assert job.state == "completed"
      assert [_name, ^address] = job.args["to"]
      refute Map.has_key?(job.args, "sealed")
      refute inspect(job.args) =~ token
    end

    test "a cancelled job forgets it too" do
      {address, _token} = queue_token_mail(:magic_link)
      use_adapter(PermanentFailureAdapter)

      capture_log(fn -> Oban.drain_queue(queue: :mail) end)

      job = job_for(address)
      assert job.state == "cancelled"
      refute Map.has_key?(job.args, "sealed")
    end

    test "a job failing its last attempt forgets it; an earlier failure keeps it" do
      {address, _token} = queue_token_mail(:confirmation)
      use_adapter(ExitingAdapter)

      capture_log(fn -> Oban.drain_queue(queue: :mail) end)
      # Still to be retried, so it still needs its message.
      assert %{"sealed" => _sealed} = job_for(address).args

      job = job_for(address)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "available", attempt: job.max_attempts - 1, scheduled_at: DateTime.utc_now()]
      )

      capture_log(fn -> Oban.drain_queue(queue: :mail) end)

      job = job_for(address)
      assert job.state == "discarded"
      refute Map.has_key?(job.args, "sealed")
    end

    test "a job with no message cancels instead of sending an empty one" do
      {address, _token} = queue_token_mail(:password_reset)
      job = job_for(address)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [args: Map.delete(job.args, "sealed")]
      )

      Oban.drain_queue(queue: :mail)

      job = job_for(address)
      assert job.state == "cancelled"
      assert [%{"error" => error}] = job.errors
      assert error =~ "message no longer available"
      assert_no_email_sent()
    end
  end

  describe "sealed args" do
    test "open under the current secret, round-tripping the message" do
      {address, token} = queue_token_mail(:password_reset)
      args = job_for(address).args

      refute Map.has_key?(args, "subject")
      refute Map.has_key?(args, "html_body")
      assert {:ok, email} = Mail.open_args(args)
      assert email.html_body =~ "/password-reset/#{token}"
      assert email.subject =~ "Reset your"
      assert email.to == [{"", address}]
    end

    test "a job queued before 1.0, in the clear, still opens" do
      legacy = %{
        "from" => ["KilnCMS", "cms@example.com"],
        "to" => ["", "reader@example.com"],
        "subject" => "Hello",
        "html_body" => "<p>Hi</p>",
        "text_body" => nil,
        "headers" => %{}
      }

      assert {:ok, %{subject: "Hello", html_body: "<p>Hi</p>"}} = Mail.open_args(legacy)
    end

    test "a seal that no longer opens is reported, not sent blank" do
      args = %{
        "from" => ["KilnCMS", "cms@example.com"],
        "to" => ["", "reader@example.com"],
        "sealed" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:error, :body_unreadable} = Mail.open_args(args)
      assert Mail.describe_open_error(:body_unreadable) =~ "PREVIOUS_SECRET_KEY_BASE"
    end
  end

  describe "Scrub.run/1 (the upgrade's data migration)" do
    @crash """
    ** (exit) exited in: GenServer.call({:global, Swoosh.Adapters.Local.Storage.Memory}, {:push, %Swoosh.Email{subject: "Reset your password", html_body: "<a href=\\"https://cms.example/password-reset/LEAKED\\">"}}, 5000)
        ** (EXIT) no process: the process is not alive
    """

    defp insert_job!(queue, state, args, errors) do
      now = DateTime.utc_now()

      {1, [%{id: id}]} =
        Repo.insert_all(
          Oban.Job,
          [
            %{
              queue: queue,
              worker: "KilnCMS.Mail.DeliveryWorker",
              state: state,
              args: args,
              errors: errors,
              attempt: 1,
              max_attempts: 8,
              inserted_at: now,
              scheduled_at: if(state == "available", do: DateTime.add(now, 3600), else: now)
            }
          ],
          returning: [:id]
        )

      id
    end

    defp entry(error), do: %{"attempt" => 1, "at" => "2026-09-30T00:00:00Z", "error" => error}

    @legacy_args %{
      "to" => ["", "reader@example.com"],
      "subject" => "Reset",
      "html_body" => ~s(<a href="https://cms.example/password-reset/LEAKED">x</a>),
      "text_body" => nil
    }

    test "redacts leaking errors and finished jobs' bodies, on the mail queues only" do
      crashed = insert_job!("mail", "discarded", @legacy_args, [entry(@crash)])
      completed = insert_job!("mail", "completed", @legacy_args, [])
      pending = insert_job!("mail", "available", @legacy_args, [entry(@crash)])

      linked =
        insert_job!("newsletter", "retryable", %{"subscriber_id" => "x"}, [
          entry("** (RuntimeError) see https://cms.example/newsletter/confirm/LEAKED\n  stack")
        ])

      harmless =
        insert_job!("mail", "cancelled", %{"to" => ["", "reader@example.com"]}, [
          entry("** (Oban.PerformError) failed with {:cancel, \"permanent delivery failure\"}")
        ])

      other_queue = insert_job!("default", "discarded", @legacy_args, [entry(@crash)])

      assert %{bodies_dropped: 2, errors_redacted: 3} = Scrub.run(Repo)

      get = &Repo.get!(Oban.Job, &1)

      for id <- [crashed, completed, pending, linked] do
        refute inspect(get.(id).errors) =~ "LEAKED"
      end

      assert [%{"error" => withheld}] = get.(crashed).errors
      assert withheld =~ "details held the message and were removed"
      refute Map.has_key?(get.(crashed).args, "html_body")
      refute Map.has_key?(get.(completed).args, "html_body")
      assert get.(completed).args["to"] == ["", "reader@example.com"]

      # Still to be delivered: keeps its message.
      assert get.(pending).args["html_body"] =~ "LEAKED"

      assert [%{"error" => "** (RuntimeError) see [link removed]"}] = get.(linked).errors

      assert [
               %{
                 "error" =>
                   "** (Oban.PerformError) failed with {:cancel, \"permanent delivery failure\"}"
               }
             ] =
               get.(harmless).errors

      # Another queue's rows are not this scrub's to touch.
      untouched = get.(other_queue)
      assert untouched.args == @legacy_args
      assert [%{"error" => @crash}] = untouched.errors

      # Idempotent.
      assert %{bodies_dropped: 0, errors_redacted: 0} = Scrub.run(Repo)
    end
  end
end
