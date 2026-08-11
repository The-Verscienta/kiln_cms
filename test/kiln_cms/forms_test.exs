defmodule KilnCMS.FormsTest do
  @moduledoc """
  The public-form submission pipeline (`KilnCMS.Forms`): per-field coercion +
  validation, honeypot discarding, unknown-key dropping, notification and
  webhook side effects — plus the `:form` block's headless placeholder.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Forms

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "form-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "form-#{System.unique_integer([:positive])}"

  defp form!(attrs \\ %{}, fields) do
    actor = admin()

    form =
      CMS.create_form!(
        Map.merge(%{name: "Contact", slug: slug()}, attrs),
        actor: actor
      )

    for {field, position} <- Enum.with_index(fields) do
      CMS.create_form_field!(
        Map.merge(%{form_id: form.id, position: position}, field),
        actor: actor
      )
    end

    Forms.get_active(form.slug)
  end

  # Autoresponder subject/body reference `[field:<name>]` tokens, and the
  # config-time validation only knows a form's fields as of *this* save — so,
  # unlike `form!/2`, the fields must exist before the autoresponder attrs are
  # set, not alongside them at creation.
  defp autoresponder_form!(autoresponder_attrs, fields) do
    form = form!(fields)

    CMS.update_form!(CMS.get_form!(form.id, authorize?: false), autoresponder_attrs,
      authorize?: false
    )

    Forms.get_active(form.slug)
  end

  test "coerces and validates each declared field type" do
    form =
      form!([
        %{name: "full_name", label: "Name", field_type: :string, required: true},
        %{name: "email", label: "Email", field_type: :email, required: true},
        %{name: "guests", label: "Guests", field_type: :integer},
        %{name: "newsletter", label: "Newsletter", field_type: :boolean},
        %{name: "visit_on", label: "Visit", field_type: :date},
        %{name: "topic", label: "Topic", field_type: :select, options: ["sales", "support"]}
      ])

    assert {:ok, submission} =
             Forms.submit(form, %{
               "full_name" => "  Ada Lovelace ",
               "email" => "ada@example.com",
               "guests" => "3",
               "newsletter" => "true",
               "visit_on" => "2026-08-01",
               "topic" => "sales",
               "not_a_field" => "dropped"
             })

    assert submission.data == %{
             "full_name" => "Ada Lovelace",
             "email" => "ada@example.com",
             "guests" => 3,
             "newsletter" => true,
             "visit_on" => "2026-08-01",
             "topic" => "sales"
           }
  end

  test "collects per-field errors" do
    form =
      form!([
        %{name: "email", label: "Email", field_type: :email, required: true},
        %{name: "guests", label: "Guests", field_type: :integer},
        %{name: "topic", label: "Topic", field_type: :select, options: ["a"]}
      ])

    assert {:error, errors} =
             Forms.submit(form, %{"email" => "nope", "guests" => "many", "topic" => "z"})

    assert errors["email"] =~ "email"
    assert errors["guests"] =~ "whole number"
    assert errors["topic"] =~ "allowed options"
  end

  test "an email field rejects a comma-separated address (#468 autoresponder hardening)" do
    # The autoresponder hands this value straight to Swoosh as a literal SMTP
    # recipient — a comma is invalid in a real address, and letting it
    # through would risk smuggling in an extra recipient.
    form = form!([%{name: "email", label: "Email", field_type: :email, required: true}])

    assert {:error, %{"email" => _}} =
             Forms.submit(form, %{"email" => "a@example.com,evil@example.com"})
  end

  test "required fields reject blank; optional blanks are skipped" do
    form =
      form!([
        %{name: "message", label: "Message", field_type: :text, required: true},
        %{name: "phone", label: "Phone", field_type: :string}
      ])

    assert {:error, %{"message" => "is required"}} = Forms.submit(form, %{"phone" => "  "})

    assert {:ok, submission} = Forms.submit(form, %{"message" => "hi"})
    refute Map.has_key?(submission.data, "phone")
  end

  test "the honeypot discards silently — fake success, nothing stored" do
    form = form!([%{name: "message", label: "Message", field_type: :text}])

    assert {:ok, :discarded} =
             Forms.submit(form, %{"message" => "spam", Forms.honeypot_field() => "gotcha"})

    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
  end

  test "an inactive form rejects submissions" do
    form = form!(%{active: true}, [])

    CMS.update_form!(CMS.get_form!(form.id, authorize?: false), %{active: false},
      authorize?: false
    )

    inactive = CMS.get_form!(form.id, authorize?: false)

    assert {:error, %{"form" => _}} = Forms.submit(inactive, %{})
    # And it disappears from the public fetch entirely.
    assert Forms.get_active(form.slug) == nil
  end

  test "a notify_email queues a mail job; a subscribed endpoint gets the webhook" do
    endpoint =
      CMS.create_webhook_endpoint!(
        %{url: "https://example.test/hook", events: ["form.submitted"]},
        actor: admin()
      )

    form =
      form!(%{notify_email: "team@example.com"}, [
        %{name: "message", label: "Message", field_type: :text}
      ])

    assert {:ok, _} = Forms.submit(form, %{"message" => "hello"})

    assert_enqueued(worker: KilnCMS.Forms.NotificationWorker)

    assert [delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
    assert delivery.endpoint_id == endpoint.id
    assert delivery.event == "form.submitted"
    assert delivery.payload["form"] == form.slug
  end

  test "an enabled autoresponder queues a mail job addressed to the submitter (#468)" do
    form =
      autoresponder_form!(
        %{
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks, [field:name]!",
          autoresponder_body: "<p>We got your message, from [form-name].</p>"
        },
        [
          %{name: "name", label: "Name", field_type: :string},
          %{name: "email", label: "Email", field_type: :email}
        ]
      )

    assert {:ok, _} = Forms.submit(form, %{"name" => "Ada", "email" => "ada@example.com"})

    assert_enqueued(
      worker: KilnCMS.Forms.AutoresponderWorker,
      args: %{"to" => "ada@example.com"}
    )
  end

  test "the autoresponder stays quiet when off, when there's no email field, or when it's blank" do
    off =
      autoresponder_form!(%{autoresponder_enabled: false}, [
        %{name: "email", label: "Email", field_type: :email}
      ])

    assert {:ok, _} = Forms.submit(off, %{"email" => "a@example.com"})
    refute_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)

    no_email_field =
      autoresponder_form!(
        %{autoresponder_enabled: true, autoresponder_subject: "s", autoresponder_body: "b"},
        [%{name: "message", label: "Message", field_type: :text}]
      )

    assert {:ok, _} = Forms.submit(no_email_field, %{"message" => "hi"})
    refute_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)

    blank_email =
      autoresponder_form!(
        %{autoresponder_enabled: true, autoresponder_subject: "s", autoresponder_body: "b"},
        [%{name: "email", label: "Email", field_type: :email}]
      )

    assert {:ok, _} = Forms.submit(blank_email, %{})
    refute_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)
  end

  test "a spam-scored submission never triggers the autoresponder" do
    form =
      autoresponder_form!(
        %{autoresponder_enabled: true, autoresponder_subject: "s", autoresponder_body: "b"},
        [
          %{name: "email", label: "Email", field_type: :email},
          %{name: "message", label: "Message", field_type: :text}
        ]
      )

    # Link density (40) alone sits under the default 50 threshold — pair it
    # with an instant fill time (30) to genuinely clear it, same as the
    # "spam scoring" describe block below.
    assert {:ok, submission} =
             Forms.submit(form, %{
               "email" => "a@example.com",
               "message" => "Buy now http://a.co http://b.co http://c.co",
               Forms.rendered_at_field() => Forms.rendered_at_token()
             })

    assert submission.status == :spam
    refute_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)
  end

  test "form.submitted is a selectable webhook event" do
    assert "form.submitted" in KilnCMS.CMS.WebhookEndpoint.events()
  end

  test "the form block fires a headless placeholder, not markup" do
    html =
      %KilnCMS.Blocks.Form{form_slug: "contact"}
      |> KilnCMS.Blocks.render(:web)
      |> IO.iodata_to_binary()

    assert html == ~s(<div data-kiln-form="contact"></div>)
  end

  describe "spam scoring (#477)" do
    test "a clean submission is stored :new with a zero score" do
      form = form!([%{name: "message", label: "Message", field_type: :text}])

      assert {:ok, submission} = Forms.submit(form, %{"message" => "Hi, I'd like a quote."})
      assert submission.status == :new
      assert submission.spam_score == 0
    end

    test "a submission that clears the threshold is stored :spam" do
      # Link density (40) alone sits under the default 50 threshold — weights
      # are meant to combine, so this pairs it with an instant fill time (30)
      # to genuinely clear it, rather than relying on one check's exact number.
      form = form!([%{name: "message", label: "Message", field_type: :text}])

      assert {:ok, submission} =
               Forms.submit(form, %{
                 "message" => "Buy now http://a.co http://b.co http://c.co",
                 Forms.rendered_at_field() => Forms.rendered_at_token()
               })

      assert submission.status == :spam
      assert submission.spam_score >= 50
    end

    test "no rendered-at token means no fill-time signal, not an error" do
      # A headless/JSON caller with no rendered page to time.
      form = form!([%{name: "message", label: "Message", field_type: :text}])
      assert {:ok, submission} = Forms.submit(form, %{"message" => "Hello there"})
      assert submission.status == :new
    end

    test "a submission filled faster than any human could contributes to the score" do
      # Fill-time alone (30) sits under the default 50 threshold — this checks
      # the signal fires and adds weight, not that it single-handedly flags.
      form = form!([%{name: "message", label: "Message", field_type: :text}])

      assert {:ok, submission} =
               Forms.submit(form, %{
                 "message" => "hi",
                 Forms.rendered_at_field() => Forms.rendered_at_token()
               })

      # Rendered and submitted in the same call — effectively 0ms fill time.
      assert submission.status == :new
      assert submission.spam_score > 0
    end

    test "a plausible human fill time is not flagged on that signal alone" do
      old_token =
        Phoenix.Token.sign(
          KilnCMSWeb.Endpoint,
          "form_rendered_at",
          System.system_time(:millisecond) - 8_000
        )

      form = form!([%{name: "message", label: "Message", field_type: :text}])

      assert {:ok, submission} =
               Forms.submit(form, %{"message" => "hi", Forms.rendered_at_field() => old_token})

      assert submission.status == :new
    end

    test "a rendered-at token minted slightly in the future (clock skew) gives no fill-time signal" do
      # A different node's clock running ahead is not evidence of a bot —
      # Forms.fill_time_ms/1 must not floor this to 0 and flag it as instant.
      future_token =
        Phoenix.Token.sign(
          KilnCMSWeb.Endpoint,
          "form_rendered_at",
          System.system_time(:millisecond) + 5_000
        )

      assert Forms.fill_time_ms(future_token) == nil

      form = form!([%{name: "message", label: "Message", field_type: :text}])

      assert {:ok, submission} =
               Forms.submit(form, %{"message" => "hi", Forms.rendered_at_field() => future_token})

      assert submission.spam_score == 0
    end

    test "a :spam submission never queues a notification or fires the webhook" do
      CMS.create_webhook_endpoint!(
        %{url: "https://example.test/hook", events: ["form.submitted"]},
        actor: admin()
      )

      form =
        form!(%{notify_email: "team@example.com"}, [
          %{name: "message", label: "Message", field_type: :text}
        ])

      assert {:ok, submission} =
               Forms.submit(form, %{
                 "message" => "Buy now http://a.co http://b.co http://c.co",
                 Forms.rendered_at_field() => Forms.rendered_at_token()
               })

      assert submission.status == :spam
      refute_enqueued(worker: KilnCMS.Forms.NotificationWorker)
      assert CMS.recent_webhook_deliveries!(authorize?: false) == []
    end

    test "an org's disallowed keywords flag a submission that mentions one" do
      admin = admin()
      form = form!([%{name: "message", label: "Message", field_type: :text}])

      CMS.save_form_spam_settings!(%{keywords: ["cryptobucks"]}, actor: admin)

      assert {:ok, submission} =
               Forms.submit(form, %{"message" => "Earn free CryptoBucks today"})

      assert submission.status == :spam
      assert :disallowed_keyword in reasons_for(submission)
    end
  end

  defp reasons_for(submission) do
    context =
      Kiln.Forms.SpamCheck.Context.new(submission.data,
        locale: submission.locale,
        keywords: ["cryptobucks"]
      )

    context
    |> Kiln.Forms.SpamCheck.Registry.run()
    |> Kiln.Forms.SpamCheck.Registry.reasons()
  end
end
