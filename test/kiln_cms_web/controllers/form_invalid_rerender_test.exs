defmodule KilnCMSWeb.FormInvalidRerenderTest do
  @moduledoc """
  A refused public form submission re-renders the SAME form (#1683): the
  visitor's values filled back in, each error shown against its field's label
  with `aria-invalid`/`aria-describedby`, and a focused summary on top — on-site
  inside the public chrome, embedded inside the iframe document under its
  framing CSP. Still a 422; valid submissions are unchanged.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Forms

  import KilnCMS.FormFixtures, only: [admin: 0, form!: 0]

  # The fixture's form (a required `email`) plus one field of each other kind
  # a visitor's value has to survive the round trip through.
  defp full_form! do
    form = form!()
    actor = admin()

    for attrs <- [
          %{
            name: "full_name",
            label: "Your name",
            field_type: :string,
            required: true,
            help_text: "As it appears on your ID"
          },
          %{name: "message", label: "Message", field_type: :text},
          %{name: "topic", label: "Topic", field_type: :select, options: ["Sales", "Support"]},
          %{name: "subscribe", label: "Keep me posted", field_type: :boolean}
        ] do
      CMS.create_form_field!(Map.put(attrs, :form_id, form.id), actor: actor)
    end

    form
  end

  defp invalid_params(extra \\ %{}) do
    Map.merge(
      %{
        "email" => "not-an-email",
        "full_name" => "",
        "message" => ~s[<script>alert("x")</script> hello],
        "topic" => "Support",
        "subscribe" => "true"
      },
      extra
    )
  end

  defp post_invalid(conn, form, extra \\ %{}) do
    conn |> unique_ip() |> post("/forms/#{form.slug}", invalid_params(extra))
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp attr(doc, selector, name) do
    case doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name) do
      [value] -> value
      [] -> nil
    end
  end

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  # Both routes must pass every assertion here; only the shell differs.
  defp assert_rerendered_form(html, form) do
    d = doc(html)
    p = "kiln-form-#{form.slug}"

    # The same form, posting back to the same place.
    assert attr(d, "form.kiln-form", "action") == "/forms/#{form.slug}"

    # The visitor's values are back in their inputs.
    assert attr(d, "##{p}-email", "value") == "not-an-email"
    assert text(d, "##{p}-message") == ~s[<script>alert("x")</script> hello]
    assert attr(d, "##{p}-topic option[selected]", "value") == "Support"
    assert attr(d, "##{p}-subscribe", "checked") != nil

    # ...escaped: the submitted markup is text, never an element.
    assert LazyHTML.query(d, "form script") |> Enum.count() == 0
    refute html =~ ~s(<script>alert)

    # Each refused field is marked invalid and described by its own error.
    for {name, message} <- [
          {"email", "Enter an email address, like name@example.com."},
          {"full_name", "This field is required."}
        ] do
      assert attr(d, "##{p}-#{name}", "aria-invalid") == "true"
      described = attr(d, "##{p}-#{name}", "aria-describedby")
      assert "#{p}-#{name}-error" in String.split(described)
      assert text(d, "##{p}-#{name}-error") =~ message
    end

    # Help text stays reachable alongside the error.
    assert attr(d, "##{p}-full_name", "aria-describedby") ==
             "#{p}-full_name-error #{p}-full_name-help"

    # Fields that passed are not marked.
    assert attr(d, "##{p}-message", "aria-invalid") == nil
    assert attr(d, "##{p}-topic", "aria-invalid") == nil

    # The summary: announced, focused on load, labels (not machine names),
    # linking to each field, in the form's order.
    summary = "##{p}-error-summary"
    assert attr(d, summary, "role") == "alert"
    assert attr(d, summary, "autofocus") != nil
    assert attr(d, summary, "tabindex") == "-1"

    links = LazyHTML.query(d, "#{summary} a")
    assert LazyHTML.attribute(links, "href") == ["##{p}-email", "##{p}-full_name"]

    assert Enum.map(links, &LazyHTML.text/1) |> Enum.map(&String.trim/1) == [
             "Email: Enter an email address, like name@example.com.",
             "Your name: This field is required."
           ]

    refute text(d, summary) =~ "full_name"
    d
  end

  describe "on-site (POST /forms/:slug)" do
    test "re-renders the form inside the public chrome with a 422", %{conn: conn} do
      form = full_form!()
      conn = post_invalid(conn, form)

      html = html_response(conn, 422)
      d = assert_rerendered_form(html, form)

      # Inside `Layouts.public`, not a bare message page.
      assert LazyHTML.query(d, ".public-shell main#main form.kiln-form") |> Enum.count() == 1
      assert text(d, "h1") =~ "Contact us"
      # Strict site CSP, no embed marker, no iframe resizer.
      assert get_resp_header(conn, "content-security-policy") |> hd() =~ "frame-ancestors 'self'"
      assert attr(d, "input[name=_kiln_embed]", "value") == nil
      refute html =~ "/embed-frame.js"

      assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
    end

    test "correcting the values then submits normally", %{conn: conn} do
      form = full_form!()

      html =
        conn
        |> unique_ip()
        |> post(
          "/forms/#{form.slug}",
          invalid_params(%{"email" => "a@b.co", "full_name" => "Ada"})
        )
        |> html_response(200)

      assert html =~ "Merci!"
      assert [submission] = CMS.recent_form_submissions!(form.id, authorize?: false)
      assert submission.data["full_name"] == "Ada"
    end
  end

  describe "embedded (POST /forms/:slug with _kiln_embed)" do
    test "re-renders the iframe document, framable, with no site chrome", %{conn: conn} do
      form = full_form!()
      conn = post_invalid(conn, form, %{"_kiln_embed" => "1"})

      html = html_response(conn, 422)
      d = assert_rerendered_form(html, form)

      assert attr(d, "input[name=_kiln_embed]", "value") == "1"
      assert html =~ "/embed-frame.js"
      assert LazyHTML.query(d, ".public-shell") |> Enum.count() == 0

      assert String.ends_with?(
               get_resp_header(conn, "content-security-policy") |> hd(),
               "frame-ancestors 'self' https://embedder.test"
             )
    end
  end

  describe "what is never echoed" do
    # Any value but "" in the honeypot is a fake success (200) before
    # validation runs — whitespace-only included since #1657 — so the only
    # honeypot value that can reach a re-render is the empty one, and the
    # re-render still renders the field empty.
    test "the honeypot is rendered empty on a re-render", %{conn: conn} do
      form = full_form!()

      html =
        conn
        |> post_invalid(form, %{"website" => ""})
        |> html_response(422)

      assert attr(doc(html), "input[name=website]", "value") == nil
    end

    test "a whitespace-only honeypot is a fake success, not a re-render (#1657)",
         %{conn: conn} do
      form = full_form!()

      html =
        conn
        |> post_invalid(form, %{"website" => "   "})
        |> html_response(200)

      assert html =~ "Merci!"
    end

    test "a filled honeypot still gets the fake success, not the re-render", %{conn: conn} do
      form = full_form!()

      html =
        conn
        |> post_invalid(form, %{"website" => "http://spam.example"})
        |> html_response(200)

      assert html =~ "Merci!"
      refute html =~ "spam.example"
    end

    test "unknown keys and non-string values are not rendered", %{conn: conn} do
      form = full_form!()

      html =
        conn
        |> post_invalid(form, %{
          "injected" => "stray-value-7f3",
          "message" => %{"nested" => "nested-value-7f3"}
        })
        |> html_response(422)

      refute html =~ "stray-value-7f3"
      refute html =~ "nested-value-7f3"
    end

    test "a still-valid fill-time token is carried over; a forged one is replaced",
         %{conn: conn} do
      form = full_form!()
      token = Forms.rendered_at_token()

      carried =
        conn
        |> post_invalid(form, %{Forms.rendered_at_field() => token})
        |> html_response(422)
        |> doc()
        |> attr("input[name=#{Forms.rendered_at_field()}]", "value")

      assert carried == token

      replaced =
        build_conn()
        |> post_invalid(form, %{Forms.rendered_at_field() => "forged"})
        |> html_response(422)
        |> doc()
        |> attr("input[name=#{Forms.rendered_at_field()}]", "value")

      refute replaced == "forged"
      assert Forms.fill_time_ms(replaced)
    end
  end

  test "the JSON endpoint's error shape is unchanged", %{conn: conn} do
    form = full_form!()

    body =
      conn
      |> unique_ip()
      |> put_req_header("content-type", "application/json")
      |> post("/api/forms/#{form.slug}", Jason.encode!(%{email: "nope"}))
      |> json_response(422)

    assert body["errors"] == %{
             "email" => "must be an email address",
             "full_name" => "is required"
           }
  end

  test "error messages follow the request locale", %{conn: conn} do
    form = full_form!()

    html =
      conn
      |> unique_ip()
      |> post("/fr/forms/#{form.slug}", invalid_params())
      |> html_response(422)

    assert html =~ "Ce champ est obligatoire."
    refute html =~ "This field is required."
  after
    Gettext.put_locale(KilnCMSWeb.Gettext, "en")
  end
end
