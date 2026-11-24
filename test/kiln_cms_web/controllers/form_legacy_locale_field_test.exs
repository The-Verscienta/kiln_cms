defmodule KilnCMSWeb.FormLegacyLocaleFieldTest do
  @moduledoc """
  A form with a field named `locale` from before the name was reserved
  (#2716). As with a legacy field named like the honeypot (#2267), the form
  keeps working exactly as before: it renders, the field's value is stored,
  and the API lists it. The `locale` param keeps meaning the submission's
  language, so the visitor's answer is recorded as that too — the reason the
  name is reserved and the builder flags the field.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp legacy_form! do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "fll-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    form =
      CMS.create_form!(
        %{
          name: "Contact",
          slug: "fll-#{System.unique_integer([:positive])}",
          success_message: "Merci!"
        },
        actor: admin
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: admin
    )

    # The create action refuses the name now, so it is written underneath it.
    Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
      form_id: form.id,
      name: "locale",
      label: "Preferred language",
      field_type: :string,
      position: 2
    })

    form
  end

  test "the page renders the field", %{conn: conn} do
    form = legacy_form!()

    html = conn |> get("/forms/#{form.slug}") |> html_response(200)

    assert html =~ "Preferred language"
    assert html =~ ~s(name="locale")
  end

  test "a submission stores the field's value, which is also recorded as its language",
       %{conn: conn} do
    form = legacy_form!()

    html =
      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "locale" => "fr"})
      |> html_response(200)

    assert html =~ "Merci!"
    assert [submission] = CMS.recent_form_submissions!(form.id, authorize?: false)
    assert submission.data == %{"email" => "a@b.co", "locale" => "fr"}
    assert submission.locale == "fr"
  end

  test "a submission that leaves it empty is stored", %{conn: conn} do
    form = legacy_form!()

    conn
    |> unique_ip()
    |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "locale" => ""})
    |> html_response(200)

    assert [submission] = CMS.recent_form_submissions!(form.id, authorize?: false)
    assert submission.data == %{"email" => "a@b.co"}
  end

  test "GET /api/forms/:slug lists the field", %{conn: conn} do
    form = legacy_form!()

    body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)

    assert Enum.map(body["fields"], & &1["name"]) == ["email", "locale"]
  end
end
