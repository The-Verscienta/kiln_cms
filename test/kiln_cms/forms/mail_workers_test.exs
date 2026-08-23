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
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Swoosh.TestAssertions

  alias KilnCMS.CMS
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

  describe "NotificationWorker" do
    test "mails notify_email a table of the submission" do
      form = form!(%{name: "Contact", notify_email: "team@example.com"})

      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => form.id,
                 "org_id" => KilnCMS.Accounts.default_org_id(),
                 "data" => %{"message" => "hello"}
               })

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
               perform_job(NotificationWorker, %{
                 "form_id" => form.id,
                 "org_id" => KilnCMS.Accounts.default_org_id(),
                 "data" => %{
                   "<img src=x onerror=\"alert(1)\">" => "<script>alert(\"xss\")</script>"
                 }
               })

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

    test "a non-string value still renders (data comes back from Oban args as JSON)" do
      form = form!(%{notify_email: "team@example.com"})

      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => form.id,
                 "org_id" => KilnCMS.Accounts.default_org_id(),
                 "data" => %{"agree" => true, "count" => 3}
               })

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

      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => form.id,
                 "org_id" => other_org().id,
                 "data" => %{"message" => "hi"}
               })

      assert_no_email_sent()
    end

    test "sends nothing when the form has no notify_email, or lost it since enqueue" do
      never_had_one = form!()

      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => never_had_one.id,
                 "data" => %{"message" => "hi"}
               })

      switched_off = form!(%{notify_email: "team@example.com"})

      CMS.update_form!(CMS.get_form!(switched_off.id, authorize?: false), %{notify_email: ""},
        authorize?: false
      )

      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => switched_off.id,
                 "data" => %{"message" => "hi"}
               })

      assert_no_email_sent()
    end

    test "a form deleted between enqueue and run is :ok, not a failing job" do
      assert :ok =
               perform_job(NotificationWorker, %{
                 "form_id" => Ecto.UUID.generate(),
                 "data" => %{"message" => "hi"}
               })

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
               perform_job(AutoresponderWorker, %{
                 "form_id" => form.id,
                 "org_id" => KilnCMS.Accounts.default_org_id(),
                 "to" => "ada@example.com",
                 "data" => %{"name" => "Ada", "email" => "ada@example.com"}
               })

      assert_email_sent(fn email ->
        # Addressed to the submitter, not to the form's notify_email — the one
        # difference from its twin that a swapped argument would silently undo.
        assert email.to == [{"", "ada@example.com"}]
        assert email.from == Application.fetch_env!(:kiln_cms, :email_from)
        assert email.subject == "Thanks, Ada!"
        assert email.html_body == "<p>We got it, Ada — from Contact.</p>"
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
               perform_job(AutoresponderWorker, %{
                 "form_id" => form.id,
                 "to" => "ada@example.com",
                 "data" => %{
                   "name" => "Ada\r\nBcc: victim@example.com <script>alert(1)</script>",
                   "email" => "ada@example.com"
                 }
               })

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
      form =
        autoresponder_form!(
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks!",
            autoresponder_body: "<p>Hi.</p>"
          },
          [%{name: "email", label: "Email", field_type: :email}]
        )

      assert :ok =
               perform_job(AutoresponderWorker, %{
                 "form_id" => form.id,
                 "org_id" => other_org().id,
                 "to" => "ada@example.com",
                 "data" => %{"email" => "ada@example.com"}
               })

      assert_no_email_sent()
    end

    test "an autoresponder switched off between enqueue and run sends nothing" do
      form =
        autoresponder_form!(
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks!",
            autoresponder_body: "<p>Hi.</p>"
          },
          [%{name: "email", label: "Email", field_type: :email}]
        )

      CMS.update_form!(CMS.get_form!(form.id, authorize?: false), %{autoresponder_enabled: false},
        authorize?: false
      )

      assert :ok =
               perform_job(AutoresponderWorker, %{
                 "form_id" => form.id,
                 "to" => "ada@example.com",
                 "data" => %{"email" => "ada@example.com"}
               })

      assert_no_email_sent()
    end

    test "a form deleted between enqueue and run is :ok, not a failing job" do
      assert :ok =
               perform_job(AutoresponderWorker, %{
                 "form_id" => Ecto.UUID.generate(),
                 "to" => "ada@example.com",
                 "data" => %{"email" => "ada@example.com"}
               })

      assert_no_email_sent()
    end

    test "backoff is the shared mail schedule, not Oban's default" do
      assert AutoresponderWorker.backoff(%Oban.Job{attempt: 1}) ==
               KilnCMS.Mail.backoff_seconds(1)

      assert AutoresponderWorker.backoff(%Oban.Job{attempt: 4}) ==
               KilnCMS.Mail.backoff_seconds(4)
    end
  end
end
