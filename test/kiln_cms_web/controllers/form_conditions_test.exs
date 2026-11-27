defmodule KilnCMSWeb.FormConditionsTest do
  @moduledoc """
  Conditional fields (#2262) through the router: the headless schema's
  `fields[].condition`, a JSON submission's `discarded`, and the markup and
  script a conditional form carries on its own page, in the embed and on a
  refused re-render.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fcond-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  @rule %{"field" => "topic", "op" => "eq", "value" => "Other"}

  defp form!(opts \\ []) do
    actor = admin()

    form =
      CMS.create_form!(
        %{name: "Contact", slug: "fcond-#{System.unique_integer([:positive])}", active: true},
        actor: actor
      )

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "topic",
        label: "Topic",
        field_type: :select,
        options: ["Sales", "Other"],
        position: 0
      },
      actor: actor
    )

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "details",
        label: "Details",
        field_type: :string,
        required: true,
        position: 1,
        condition: if(Keyword.get(opts, :conditional, true), do: %{action: :show, rule: @rule})
      },
      actor: actor
    )

    form
  end

  defp json_post(conn, form, body) do
    conn
    |> unique_ip()
    |> put_req_header("content-type", "application/json")
    |> post("/api/forms/#{form.slug}", Jason.encode!(body))
  end

  describe "GET /api/forms/:slug" do
    test "each field carries its condition, null when it has none", %{conn: conn} do
      form = form!()
      body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)

      assert [topic, details] = body["fields"]
      assert topic["condition"] == nil
      assert details["condition"] == %{"action" => "show", "rule" => @rule}
      # Every key the schema already had is still there.
      assert details |> Map.keys() |> Enum.sort() ==
               ~w(condition default_value help_text label max min name options placeholder required step type width)
    end

    test "a rule an older release left dangling reads as null", %{conn: conn} do
      form = form!()

      details =
        form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "details"))

      KilnCMS.Repo.query!("UPDATE form_fields SET condition = $1 WHERE id = $2", [
        %{"action" => "show", "rule" => %{"field" => "gone", "op" => "not_empty"}},
        Ecto.UUID.dump!(details.id)
      ])

      body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)
      assert Enum.find(body["fields"], &(&1["name"] == "details"))["condition"] == nil
    end
  end

  describe "POST /api/forms/:slug" do
    test "a hidden required field may be left out", %{conn: conn} do
      form = form!()
      body = conn |> json_post(form, %{"topic" => "Sales"}) |> json_response(200)
      assert body["ok"] == true
      refute Map.has_key?(body, "discarded")
    end

    test "a value sent for a hidden field is not stored, and is listed as discarded", %{
      conn: conn
    } do
      form = form!()

      body =
        conn
        |> json_post(form, %{"topic" => "Sales", "details" => "smuggled"})
        |> json_response(200)

      assert body == %{"ok" => true, "message" => nil, "discarded" => ["details"]}
      assert [submission] = CMS.recent_form_submissions!(form.id, authorize?: false)
      assert submission.data == %{"topic" => "Sales"}
    end

    test "a shown required field is still refused when missing", %{conn: conn} do
      form = form!()
      body = conn |> json_post(form, %{"topic" => "Other"}) |> json_response(422)
      assert body == %{"ok" => false, "errors" => %{"details" => "is required"}}
    end

    test "a tripped honeypot answers with the same discarded list", %{conn: conn} do
      form = form!()

      body =
        conn
        |> json_post(form, %{"topic" => "Sales", "details" => "x", "website" => "bot"})
        |> json_response(200)

      assert body["discarded"] == ["details"]
      assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
    end
  end

  describe "the rendered form" do
    test "a conditional form is marked, carries its rules and loads the form script", %{
      conn: conn
    } do
      form = form!()
      html = conn |> unique_ip() |> get("/forms/#{form.slug}") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query("form.kiln-form[data-kiln-enhance]") |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s([data-kiln-field="topic"])) |> Enum.count() == 1

      [condition] =
        doc
        |> LazyHTML.query(~s([data-kiln-field="details"]))
        |> LazyHTML.attribute("data-kiln-condition")

      assert Jason.decode!(condition) == %{"action" => "show", "rule" => @rule}

      # No browser `required` on a field that may be hidden; the script
      # restores it while the field is shown, and the server decides.
      input = LazyHTML.query(doc, ~s(input[name="details"]))
      assert LazyHTML.attribute(input, "required") == []
      assert LazyHTML.attribute(input, "data-kiln-required") == [""]
      assert html =~ "Depends on an earlier answer"

      # The URL the challenge widget loads it from (`ChallengeComponents`),
      # digest included, so a page with both runs the module once.
      src =
        Phoenix.VerifiedRoutes.static_path(KilnCMSWeb.Endpoint, "/assets/js/challenge_static.js")

      assert doc |> LazyHTML.query("form script[src]") |> LazyHTML.attribute("src") == [src]

      # No inline script.
      assert doc |> LazyHTML.query("form script:not([src])") |> Enum.count() == 0
    end

    test "a form with no condition carries none of it", %{conn: conn} do
      form = form!(conditional: false)
      html = conn |> unique_ip() |> get("/forms/#{form.slug}") |> html_response(200)

      refute html =~ "data-kiln-enhance"
      refute html =~ "data-kiln-field"
      refute html =~ "challenge_static.js"
      assert html =~ ~r/<input[^>]*name="details"[^>]*required/s
    end

    test "the embed loads the form script for a conditional form only", %{conn: conn} do
      conditional = form!()
      plain = form!(conditional: false)

      assert conn |> unique_ip() |> get("/forms/#{conditional.slug}/embed") |> html_response(200) =~
               ~s(src="/assets/js/challenge_static.js")

      refute build_conn()
             |> unique_ip()
             |> get("/forms/#{plain.slug}/embed")
             |> html_response(200) =~
               "challenge_static.js"
    end

    test "a refused re-render keeps the rules and the script", %{conn: conn} do
      form = form!()

      html =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"topic" => "Other"})
        |> html_response(422)

      assert html =~ "data-kiln-condition"
      assert html =~ ~s(src="/assets/js/challenge_static.js")
      assert html =~ ~s(id="kiln-form-#{form.slug}-details-error")
    end
  end
end
