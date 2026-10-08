defmodule KilnCMSWeb.NewsletterSignupBlockTest do
  @moduledoc """
  A page carrying a newsletter sign-up block (#1870), end to end: what the
  page renders is a form the sign-up endpoint actually accepts.
  """
  use KilnCMSWeb.ConnCase, async: true

  require Ash.Query

  alias KilnCMS.CMS.Page

  defp page(block) do
    Ash.Seed.seed!(Page, %{
      title: "Releases",
      slug: "nl-#{System.unique_integer([:positive])}",
      state: :published,
      blocks: [Map.put(block, "_type", "newsletter_signup")]
    })
  end

  defp find(email) do
    KilnCMS.Newsletter.Subscriber
    |> Ash.Query.filter(email == ^email)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # The rendered form's action and its named inputs, read off the page rather
  # than assumed, so a renamed input fails here instead of silently on-site.
  defp rendered_form(html) do
    [form] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("form.kiln-newsletter-signup")
      |> Enum.to_list()

    names =
      form
      |> LazyHTML.query("input[name]")
      |> LazyHTML.attribute("name")

    {form |> LazyHTML.attribute("action") |> List.first(), names}
  end

  test "renders the sign-up on-site and the endpoint accepts what it posts", %{conn: conn} do
    page = page(%{"heading" => "Get the release notes", "collect_name" => true})

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert html =~ "Get the release notes"
    {action, names} = rendered_form(html)
    assert action == "/newsletter/subscribe"
    assert Enum.sort(names) == Enum.sort(["email", "name", KilnCMS.Forms.honeypot_field()])

    email = "block-#{System.unique_integer([:positive])}@example.com"

    response =
      build_conn()
      |> post(action, %{
        "email" => email,
        "name" => "Reader",
        KilnCMS.Forms.honeypot_field() => ""
      })
      |> html_response(200)

    assert response =~ "Check your inbox"
    assert %{status: :pending, name: "Reader"} = find(email)
  end

  test "a bot filling the rendered honeypot subscribes nobody", %{conn: conn} do
    page = page(%{})
    {action, _names} = conn |> get(~p"/#{page.slug}") |> html_response(200) |> rendered_form()

    email = "bot-#{System.unique_integer([:positive])}@example.com"

    build_conn()
    |> post(action, %{"email" => email, KilnCMS.Forms.honeypot_field() => "http://spam"})
    |> html_response(200)

    assert find(email) == nil
  end
end
