defmodule KilnCMS.Forms.MailWorkersTest do
  @moduledoc """
  The two mail jobs a form submission queues: `NotificationWorker` (the admin
  copy) and `AutoresponderWorker` (the submitter's confirmation).

  `KilnCMS.FormsTest` proves both are *enqueued* under the right conditions and
  stops there, so until now nothing ran `perform/1` — which is where the parts
  that matter live. Every value in either mail is anonymous, visitor-supplied
  input: the notification builds its table by string concatenation and relies
  entirely on its own `h/1` to escape it, and both re-fetch the form at
  *perform* time, so a form deleted or switched off between enqueue and run
  must send nothing rather than crash a job that will then retry four times.

  Since #2992 a job carries the submission's id and the worker reads the
  submission back, so the visitor's data never sits in `oban_jobs`. The
  "legacy jobs" blocks run the shape queued before that (`data`, and the
  autoresponder's `to`, in the args), which both workers still deliver.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Swoosh.TestAssertions

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Forms
  alias KilnCMS.Forms.AutoresponderWorker
  alias KilnCMS.Forms.NotificationWorker

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "form-mail-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(attrs \\ %{}, fields \\ []) do
    actor = admin()

    form =
      CMS.create_form!(
        Map.merge(%{name: "Contact", slug: "form-#{System.unique_integer([:positive])}"}, attrs),
        actor: actor
      )

    for {field, position} <- Enum.with_index(fields) do
      CMS.create_form_field!(
        Map.merge(%{form_id: form.id, position: position}, field),
        actor: actor
      )
    end

    form
  end

  # A second site, to show the `org_id` arg really scopes the re-fetch. The
  # *fallback* it guards (`args["org_id"] || default_org_id()`) is not
  # observable here: this build is fail-open, where a nil tenant reads globally
  # and finds the row by its unique id anyway — only the strict build
  # (`KILN_STRICT_TEST`, its own smoke suite) can tell those two apart.
  defp other_org do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: "other",
      slug: "other-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  # The autoresponder's subject/body reference `[field:<name>]` tokens, and the
  # config-time validation only knows the fields that exist at *this* save — so
  # the fields have to be created before the autoresponder attrs are set, not
  # alongside them (same ordering `KilnCMS.FormsTest` needs).
  defp autoresponder_form!(attrs, fields) do
    form = form!(%{}, fields)

    CMS.update_form!(CMS.get_form!(form.id, authorize?: false), attrs, authorize?: false)
  end

  # A stored submission, recorded the way `Forms.submit/3` records one, and
  # the args a job queued for it carries (#2992).
  defp submission!(form, data) do
    submission =
      CMS.create_form_submission!(%{form_id: form.id, data: data},
        actor: Forms.system(),
        tenant: form.org_id
      )

    assert submission.status == :new
    submission
  end

  defp args!(form, data) do
    %{
      "form_id" => form.id,
      "org_id" => form.org_id,
      "submission_id" => submission!(form, data).id
    }
  end

  defp job_row(id), do: Repo.one!(from(j in Oban.Job, where: j.id == ^id))

  defp simple_autoresponder_form! do
    autoresponder_form!(
      %{
        autoresponder_enabled: true,
        autoresponder_subject: "Thanks!",
        autoresponder_body: "<p>Hi.</p>"
      },
      [%{name: "email", label: "Email", field_type: :email}]
    )
  end

  # A job inserted for real and run through the queue, so the worker's own
  # write to its row (`PrivateArgs.finishing/3`) happens: `perform_job/3`
  # builds a job with no id, which that write leaves alone.
  defp insert!(worker, args), do: args |> worker.new() |> Oban.insert!()

  describe "NotificationWorker" do
    test "goes out through the site's own relay when it has one (#1322)" do
      form = form!(%{name: "Contact", notify_email: "team@example.com"})
      org_id = KilnCMS.Accounts.default_org_id()

      CMS.save_site_mail_relay!(
        %{host: "smtp.example.com", from_email: "forms@site.example"},
        tenant: org_id,
        authorize?: false
      )

      assert :ok = perform_job(NotificationWorker, args!(form, %{"message" => "hello"}))

      assert_received {:site_relay_email, %{from: {_name, "forms@site.example"}}, config}
      assert config[:relay] == "smtp.example.com"
      assert_no_email_sent()
    end

    test "mails notify_email a table of the submission" do
      form = form!(%{name: "Contact", notify_email: "team@example.com"})

      assert :ok = perform_job(NotificationWorker, args!(form, %{"message" => "hello"}))

      assert_email_sent(fn email ->
        assert email.to == [{"", "team@example.com"}]
        assert email.from == Application.fetch_env!(:kiln_cms, :email_from)
        assert email.subject == "New submission: Contact"
        assert email.html_body =~ "<strong>message</strong>"
        assert email.html_body =~ "hello"
      end)
    end

    test "escapes the visitor's keys and values, and the form name, into the table" do
      form = form!(%{name: "Contact <b>us</b>", notify_email: "team@example.com"})

      assert :ok =
               perform_job(
                 NotificationWorker,
                 args!(form, %{
                   "<img src=x onerror=\"alert(1)\">" => "<script>alert(\"xss\")</script>"
                 })
               )

      assert_email_sent(fn email ->
        # The whole point of `h/1`: nothing a visitor typed reaches the admin's
        # mail client as live markup. Asserting the escaped forms are *present*
        # would pass on a body that also contained the raw tag, so assert the
        # raw ones are absent too.
        refute email.html_body =~ "<script>"
        refute email.html_body =~ "<img"
        refute email.html_body =~ "onerror=\"alert"
        assert email.html_body =~ "&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;"
        assert email.html_body =~ "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;"

        # The form name is the site's own copy rather than the visitor's, but it
        # goes through the same table and is escaped with it. (A `refute` returns
        # false, and Swoosh requires this function to end truthy — so the
        # positive assertion goes last.)
        refute email.html_body =~ "<b>us</b>"
        assert email.html_body =~ "&lt;b&gt;us&lt;/b&gt;"
      end)
    end

    test "a checkboxes list and a decimal render as joined text (#2261)" do
      form = form!(%{notify_email: "team@example.com"})

      assert :ok =
               perform_job(
                 NotificationWorker,
                 args!(form, %{"topics" => ["a", "b"], "amount" => 2.5})
               )

      assert_email_sent(fn email ->
        assert email.html_body =~ "a, b"
        assert email.html_body =~ "2.5"
      end)
    end

    test "a non-string value still renders (data comes back from the stored JSON)" do
      form = form!(%{notify_email: "team@example.com"})

      assert :ok =
               perform_job(NotificationWorker, args!(form, %{"agree" => true, "count" => 3}))

      assert_email_sent(fn email ->
        assert email.html_body =~ "true"
        assert email.html_body =~ "3"
      end)
    end

    test "a pre-#336 job carrying no org_id is still delivered" do
      form = form!(%{notify_email: "team@example.com"})

      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => form.id,
                 "data" => %{"message" => "hi"}
               })

      assert_email_sent(fn email -> assert email.to == [{"", "team@example.com"}] end)
    end

    test "the org_id in the args is what scopes the re-fetch" do
      form = form!(%{notify_email: "team@example.com"})
      args = Map.put(args!(form, %{"message" => "hi"}), "org_id", other_org().id)

      assert :ok = perform_job(NotificationWorker, args)

      assert_no_email_sent()
    end

    test "sends nothing when the form has no notify_email, or lost it since enqueue" do
      never_had_one = form!()

      assert :ok = perform_job(NotificationWorker, args!(never_had_one, %{"message" => "hi"}))

      switched_off = form!(%{notify_email: "team@example.com"})
      args = args!(switched_off, %{"message" => "hi"})

      CMS.update_form!(CMS.get_form!(switched_off.id, authorize?: false), %{notify_email: ""},
        authorize?: false
      )

      assert :ok = perform_job(NotificationWorker, args)

      assert_no_email_sent()
    end

    test "a form deleted between enqueue and run is :ok, not a failing job" do
      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => Ecto.UUID.generate(),
                 "submission_id" => Ecto.UUID.generate()
               })

      assert_no_email_sent()
    end

    test "a submission deleted between enqueue and run sends nothing, and the job is done" do
      form = form!(%{notify_email: "team@example.com"})
      args = args!(form, %{"message" => "hi"})

      CMS.get_form_submission!(args["submission_id"], authorize?: false, tenant: form.org_id)
      |> CMS.destroy_form_submission!(authorize?: false, tenant: form.org_id)

      assert :ok = perform_job(NotificationWorker, args)
      assert_no_email_sent()
    end

    test "a submission marked spam between enqueue and run sends nothing" do
      form = form!(%{notify_email: "team@example.com"})
      args = args!(form, %{"message" => "hi"})

      CMS.get_form_submission!(args["submission_id"], authorize?: false, tenant: form.org_id)
      |> CMS.mark_form_submission_spam!(authorize?: false, tenant: form.org_id)

      assert :ok = perform_job(NotificationWorker, args)
      assert_no_email_sent()
    end

    test "backoff is the shared mail schedule, not Oban's default" do
      assert NotificationWorker.backoff(%Oban.Job{attempt: 1}) ==
               KilnCMS.Mail.backoff_seconds(1)

      assert NotificationWorker.backoff(%Oban.Job{attempt: 4}) ==
               KilnCMS.Mail.backoff_seconds(4)
    end
  end

  describe "AutoresponderWorker" do
    test "mails the submitter their rendered confirmation" do
      form =
        autoresponder_form!(
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks, [field:name]!",
            autoresponder_body: "<p>We got it, [field:name] — from [form-name].</p>"
          },
          [
            %{name: "name", label: "Name", field_type: :string},
            %{name: "email", label: "Email", field_type: :email}
          ]
        )

      assert :ok =
               perform_job(
                 AutoresponderWorker,
                 args!(form, %{"name" => "Ada", "email" => "ada@example.com"})
               )

      assert_email_sent(fn email ->
        # Addressed to the submitter, not to the form's notify_email — the one
        # difference from its twin that a swapped argument would silently undo.
        assert email.to == [{"", "ada@example.com"}]
        assert email.from == Application.fetch_env!(:kiln_cms, :email_from)
        assert email.subject == "Thanks, Ada!"
        assert email.html_body == "<p>We got it, Ada — from Contact.</p>"
      end)
    end

    test "a field renamed after the template was saved still renders its value (#2343)" do
      form =
        autoresponder_form!(
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks, [field:name]!",
            autoresponder_body: "<p>Hi [field:name].</p>"
          },
          [
            %{name: "name", label: "Name", field_type: :string},
            %{name: "email", label: "Email", field_type: :email}
          ]
        )

      admin = admin()
      name = form.id |> CMS.form_fields_for!(actor: admin) |> Enum.find(&(&1.name == "name"))
      CMS.update_form_field!(name, %{name: "full_name"}, actor: admin)

      # Submissions from now on carry the value under the new key.
      assert :ok =
               perform_job(
                 AutoresponderWorker,
                 args!(form, %{"full_name" => "Ada", "email" => "ada@example.com"})
               )

      assert_email_sent(fn email ->
        assert email.subject == "Thanks, Ada!"
        assert email.html_body == "<p>Hi Ada.</p>"
      end)
    end

    test "the mail carries the escaped body and a header-safe subject" do
      form =
        autoresponder_form!(
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks, [field:name]!",
            autoresponder_body: "<p>Hi [field:name].</p>"
          },
          [
            %{name: "name", label: "Name", field_type: :string},
            %{name: "email", label: "Email", field_type: :email}
          ]
        )

      assert :ok =
               perform_job(
                 AutoresponderWorker,
                 args!(form, %{
                   "name" => "Ada\r\nBcc: victim@example.com <script>alert(1)</script>",
                   "email" => "ada@example.com"
                 })
               )

      assert_email_sent(fn email ->
        # `Autoresponder.render/3` decides both of these; this asserts the
        # worker mails *that* rendering rather than re-deriving either.
        refute email.subject =~ "\r"
        refute email.subject =~ "\n"
        refute email.html_body =~ "<script>"
        assert email.html_body =~ "&lt;script&gt;"
      end)
    end

    test "a pre-#336 job carrying no org_id is still delivered, tokens and all" do
      form =
        autoresponder_form!(
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks, [field:name]!",
            autoresponder_body: "<p>Hi [field:name].</p>"
          },
          [
            %{name: "name", label: "Name", field_type: :string},
            %{name: "email", label: "Email", field_type: :email}
          ]
        )

      assert :ok =
               perform_job(AutoresponderWorker, %{
                 "form_id" => form.id,
                 "to" => "ada@example.com",
                 "data" => %{"name" => "Ada", "email" => "ada@example.com"}
               })

      # The fields read is the one that would come back empty on a wrong
      # tenant: the mail would still send, with the token unresolved.
      assert_email_sent(fn email -> assert email.subject == "Thanks, Ada!" end)
    end

    test "the org_id in the args is what scopes the re-fetch" do
      form = simple_autoresponder_form!()
      args = Map.put(args!(form, %{"email" => "ada@example.com"}), "org_id", other_org().id)

      assert :ok = perform_job(AutoresponderWorker, args)

      assert_no_email_sent()
    end

    test "an autoresponder switched off between enqueue and run sends nothing" do
      form = simple_autoresponder_form!()
      args = args!(form, %{"email" => "ada@example.com"})

      CMS.update_form!(CMS.get_form!(form.id, authorize?: false), %{autoresponder_enabled: false},
        authorize?: false
      )

      assert :ok = perform_job(AutoresponderWorker, args)

      assert_no_email_sent()
    end

    test "an email field removed between enqueue and run sends nothing (eligibility is re-asked)" do
      form = simple_autoresponder_form!()
      args = args!(form, %{"email" => "ada@example.com"})

      admin = admin()

      form.id
      |> CMS.form_fields_for!(actor: admin)
      |> Enum.each(&CMS.destroy_form_field!(&1, actor: admin))

      assert :ok = perform_job(AutoresponderWorker, args)

      assert_no_email_sent()
    end

    test "a form deleted between enqueue and run is :ok, not a failing job" do
      assert :ok =
               perform_job(AutoresponderWorker, %{
                 "form_id" => Ecto.UUID.generate(),
                 "submission_id" => Ecto.UUID.generate()
               })

      assert_no_email_sent()
    end

    test "a submission deleted between enqueue and run sends nothing, and the job is done" do
      form = simple_autoresponder_form!()
      args = args!(form, %{"email" => "ada@example.com"})

      CMS.get_form_submission!(args["submission_id"], authorize?: false, tenant: form.org_id)
      |> CMS.destroy_form_submission!(authorize?: false, tenant: form.org_id)

      assert :ok = perform_job(AutoresponderWorker, args)
      assert_no_email_sent()
    end

    test "a submission marked spam between enqueue and run sends nothing" do
      form = simple_autoresponder_form!()
      args = args!(form, %{"email" => "ada@example.com"})

      CMS.get_form_submission!(args["submission_id"], authorize?: false, tenant: form.org_id)
      |> CMS.mark_form_submission_spam!(authorize?: false, tenant: form.org_id)

      assert :ok = perform_job(AutoresponderWorker, args)
      assert_no_email_sent()
    end

    test "backoff is the shared mail schedule, not Oban's default" do
      assert AutoresponderWorker.backoff(%Oban.Job{attempt: 1}) ==
               KilnCMS.Mail.backoff_seconds(1)

      assert AutoresponderWorker.backoff(%Oban.Job{attempt: 4}) ==
               KilnCMS.Mail.backoff_seconds(4)
    end
  end

  describe "legacy jobs, queued before #2992 with the data in their args" do
    test "the notification is still delivered, and the finished row keeps no data" do
      form = form!(%{notify_email: "team@example.com"})

      job =
        insert!(NotificationWorker, %{
          "form_id" => form.id,
          "org_id" => form.org_id,
          "data" => %{"message" => "legacy-secret"}
        })

      Oban.drain_queue(queue: :mail)

      assert_email_sent(fn email -> assert email.html_body =~ "legacy-secret" end)

      row = job_row(job.id)
      assert row.state == "completed"
      assert row.args == %{"form_id" => form.id, "org_id" => form.org_id}
    end

    test "the autoresponder is still delivered to the queued address, and forgets it and the data" do
      form = simple_autoresponder_form!()

      job =
        insert!(AutoresponderWorker, %{
          "form_id" => form.id,
          "org_id" => form.org_id,
          "to" => "legacy@example.com",
          "data" => %{"email" => "legacy@example.com"}
        })

      Oban.drain_queue(queue: :mail)

      assert_email_sent(fn email -> assert email.to == [{"", "legacy@example.com"}] end)

      row = job_row(job.id)
      assert row.state == "completed"
      assert row.args == %{"form_id" => form.id, "org_id" => form.org_id}
    end

    test "a form deleted since forgets the data too (the job is done)" do
      job =
        insert!(NotificationWorker, %{
          "form_id" => Ecto.UUID.generate(),
          "data" => %{"message" => "legacy-secret"}
        })

      Oban.drain_queue(queue: :mail)

      row = job_row(job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "data")
    end

    test "a failure with attempts left keeps the data; failing the last attempt forgets it" do
      form = form!(%{notify_email: "team@example.com"})

      job =
        insert!(NotificationWorker, %{
          "form_id" => form.id,
          "org_id" => form.org_id,
          "data" => %{"message" => "legacy-secret"}
        })

      # A lost grant fails the read with `Forbidden`: an error, so a retry.
      Forms.with_actor(nil, fn ->
        capture_log(fn -> Oban.drain_queue(queue: :mail) end)
      end)

      row = job_row(job.id)
      assert row.state == "retryable"
      assert row.args["data"] == %{"message" => "legacy-secret"}

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "available", attempt: row.max_attempts - 1, scheduled_at: DateTime.utc_now()]
      )

      Forms.with_actor(nil, fn ->
        capture_log(fn -> Oban.drain_queue(queue: :mail) end)
      end)

      row = job_row(job.id)
      assert row.state == "discarded"
      refute Map.has_key?(row.args, "data")
      assert_no_email_sent()
    end
  end

  describe "new jobs carry ids, not the submission (#2992)" do
    test "a finished notification job's row is the three ids, before and after" do
      form = form!(%{notify_email: "team@example.com"})
      args = args!(form, %{"message" => "new-secret"})
      job = insert!(NotificationWorker, args)

      Oban.drain_queue(queue: :mail)

      assert_email_sent(fn email -> assert email.html_body =~ "new-secret" end)
      row = job_row(job.id)
      assert row.state == "completed"
      assert row.args == args
      refute inspect(row) =~ "new-secret"
    end
  end
end
