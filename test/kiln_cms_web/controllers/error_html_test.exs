defmodule KilnCMSWeb.ErrorHTMLTest do
  use KilnCMSWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  # #145: 404 is a branded page in the public chrome with recovery links.
  test "renders a branded 404.html with public chrome and recovery links" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", [])

    assert html =~ "Page not found"
    assert html =~ "Powered by KilnCMS."
    assert html =~ ~s(href="/blog")
  end

  # 500 and 403 are branded pages too (audit): a crash or forbidden page gets
  # public chrome and a recovery link, not bare status text.
  test "renders a branded 500.html with recovery links" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "500", "html", [])

    assert html =~ "Something went wrong"
    assert html =~ ~s(href="/")
  end

  test "renders a branded 403.html with a sign-in link" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "403", "html", [])

    assert html =~ "Access denied"
    assert html =~ ~s(href="/sign-in")
  end

  # Statuses without a template still fall through to the plain status message.
  test "renders the plain status message for untemplated statuses" do
    assert render_to_string(KilnCMSWeb.ErrorHTML, "502", "html", []) == "Bad Gateway"
  end
end
