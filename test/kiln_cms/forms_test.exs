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
end
