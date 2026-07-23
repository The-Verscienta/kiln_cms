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

  # --- phase 2 field types ------------------------------------------------------

  test "coerces the phase-2 field types" do
    form =
      form!([
        %{name: "phone", label: "Phone", field_type: :phone},
        %{name: "site", label: "Site", field_type: :url},
        %{name: "amount", label: "Amount", field_type: :number},
        %{name: "stars", label: "Stars", field_type: :rating},
        %{name: "colors", label: "Colors", field_type: :checkboxes, options: ["red", "blue"]},
        %{name: "plan", label: "Plan", field_type: :radio, options: ["basic", "pro"]},
        %{name: "source", label: "Source", field_type: :hidden, default_value: "landing-a"}
      ])

    assert {:ok, submission} =
             Forms.submit(form, %{
               "phone" => "+1 (555) 123-4567",
               "site" => "https://example.com/a",
               "amount" => "12.5",
               "stars" => "4",
               "colors" => ["red", "blue"],
               "plan" => "pro",
               "source" => "landing-a"
             })

    assert submission.data == %{
             "phone" => "+1 (555) 123-4567",
             "site" => "https://example.com/a",
             "amount" => 12.5,
             "stars" => 4,
             "colors" => ["red", "blue"],
             "plan" => "pro",
             "source" => "landing-a"
           }
  end

  test "rejects invalid phase-2 values per type" do
    form =
      form!([
        %{name: "phone", label: "Phone", field_type: :phone},
        %{name: "site", label: "Site", field_type: :url},
        %{name: "stars", label: "Stars", field_type: :rating},
        %{name: "colors", label: "Colors", field_type: :checkboxes, options: ["red", "blue"]}
      ])

    assert {:error, errors} =
             Forms.submit(form, %{
               "phone" => "not a phone",
               "site" => "javascript:alert(1)",
               "stars" => "9",
               "colors" => ["red", "green"]
             })

    assert errors["phone"] =~ "phone"
    assert errors["site"] =~ "web address"
    assert errors["stars"] =~ "1 to 5"
    assert errors["colors"] =~ "allowed options"
  end

  test "display-only fields never produce values; hidden carries its value" do
    form =
      form!([
        %{name: "intro", label: "About you", field_type: :heading},
        %{name: "sep", label: "Divider", field_type: :divider},
        %{name: "email", label: "Email", field_type: :email}
      ])

    assert {:ok, submission} =
             Forms.submit(form, %{
               "email" => "a@b.co",
               # Even a crafted param for a display field is ignored.
               "intro" => "spoofed",
               "sep" => "spoofed"
             })

    assert submission.data == %{"email" => "a@b.co"}
  end

  test "a required consent must be accepted, not merely present" do
    form = form!([%{name: "gdpr", label: "I agree", field_type: :consent, required: true}])

    assert {:error, %{"gdpr" => "must be accepted"}} =
             Forms.submit(form, %{"gdpr" => "false"})

    assert {:error, %{"gdpr" => "must be accepted"}} = Forms.submit(form, %{})
    assert {:ok, submission} = Forms.submit(form, %{"gdpr" => "true"})
    assert submission.data == %{"gdpr" => true}
  end

  test "a required checkboxes field needs at least one choice" do
    form =
      form!([
        %{
          name: "colors",
          label: "Colors",
          field_type: :checkboxes,
          options: ["red", "blue"],
          required: true
        }
      ])

    assert {:error, %{"colors" => "is required"}} = Forms.submit(form, %{"colors" => []})
    assert {:ok, _submission} = Forms.submit(form, %{"colors" => "red"})
  end

  # --- validation rules ---------------------------------------------------------

  test "enforces length, range and pattern rules server-side" do
    form =
      form!([
        %{
          name: "code",
          label: "Code",
          field_type: :string,
          validation: %{"pattern" => "[A-Z]{2}-\\d+", "message" => "use the AB-123 format"}
        },
        %{
          name: "bio",
          label: "Bio",
          field_type: :text,
          validation: %{"min_length" => 5, "max_length" => 10}
        },
        %{name: "qty", label: "Qty", field_type: :integer, validation: %{"min" => 2, "max" => 8}}
      ])

    assert {:error, errors} =
             Forms.submit(form, %{"code" => "nope", "bio" => "hey", "qty" => "12"})

    assert errors["code"] == "use the AB-123 format"
    assert errors["bio"] =~ "at least 5"
    assert errors["qty"] =~ "at most 8"

    assert {:ok, submission} =
             Forms.submit(form, %{"code" => "AB-123", "bio" => "hey there", "qty" => "5"})

    assert submission.data == %{"code" => "AB-123", "bio" => "hey there", "qty" => 5}
  end

  test "the pattern is anchored — partial matches don't pass" do
    form =
      form!([
        %{name: "code", label: "Code", field_type: :string, validation: %{"pattern" => "\\d{3}"}}
      ])

    assert {:error, _errors} = Forms.submit(form, %{"code" => "abc 123 xyz"})
    assert {:ok, _submission} = Forms.submit(form, %{"code" => "123"})
  end

  test "a broken validation pattern is rejected at write time" do
    actor = admin()
    form = CMS.create_form!(%{name: "Contact", slug: slug()}, actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.create_form_field(
               %{
                 form_id: form.id,
                 name: "code",
                 label: "Code",
                 validation: %{"pattern" => "([unclosed"}
               },
               actor: actor
             )

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.create_form_field(
               %{
                 form_id: form.id,
                 name: "code",
                 label: "Code",
                 validation: %{"bogus_rule" => 1}
               },
               actor: actor
             )
  end

  test "radio and checkboxes fields require options at write time" do
    actor = admin()
    form = CMS.create_form!(%{name: "Contact", slug: slug()}, actor: actor)

    for type <- [:radio, :checkboxes] do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_form_field(
                 %{form_id: form.id, name: "choice_#{type}", label: "Choice", field_type: type},
                 actor: actor
               )
    end
  end

  test "checkbox list values render joined in the notification email" do
    form =
      form!(%{notify_email: "team@example.com"}, [
        %{name: "colors", label: "Colors", field_type: :checkboxes, options: ["red", "blue"]}
      ])

    assert {:ok, _submission} = Forms.submit(form, %{"colors" => ["red", "blue"]})

    assert [job] = all_enqueued(worker: KilnCMS.Forms.NotificationWorker)
    perform_job(KilnCMS.Forms.NotificationWorker, job.args)

    Swoosh.TestAssertions.assert_email_sent(fn sent ->
      sent.html_body =~ "red, blue"
    end)
  end
end
