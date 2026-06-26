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

  # Statuses without a template still fall through to the plain status message.
  test "renders 500.html" do
    assert render_to_string(KilnCMSWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
