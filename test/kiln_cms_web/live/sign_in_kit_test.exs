defmodule KilnCMSWeb.SignInKitTest do
  @moduledoc """
  The sign-in page's look and its passkey affordance (#1681).

    * **Kit classes** — `KilnCMSWeb.AuthOverrides` hands the library's
      components the design language's named rules (`.btn`, `.field-*`,
      `.auth-*`) rather than bespoke utility stacks, so the sign-in page and
      Kiln's own templates draw one button and one input.
    * **The passkey button is server-rendered** — in the page's markup, with
      translated copy, hidden until the `PasskeySignIn` hook finds WebAuthn.
      It used to be injected by app.js, which no test could see.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the password form is drawn with kit classes, not bespoke utilities", %{conn: conn} do
    {:ok, _lv, html} = conn |> unique_ip() |> live(~p"/sign-in")
    doc = LazyHTML.from_document(html)

    assert count(doc, ".auth-page .auth-card") >= 1
    assert count(doc, "label.field-label") >= 2
    assert count(doc, "input.field-input[name='user[email]']") >= 1
    assert count(doc, "input.field-input[name='user[password]']") >= 1
    assert count(doc, "button[type='submit'].btn.btn-primary.btn-block") >= 1

    # The stack AuthOverrides used to spell out for every submit button.
    refute html =~ "rounded-lg bg-primary px-4 py-2.5"
  end

  describe "the passkey button" do
    test "is in the server-rendered markup, hidden until the hook reveals it", %{conn: conn} do
      conn = unique_ip(conn)

      # Disconnected (the HTML a browser first receives) and connected alike.
      dead = conn |> get(~p"/sign-in") |> html_response(200)
      {:ok, lv, _html} = live(conn, ~p"/sign-in")

      for html <- [dead, render(lv)] do
        doc = LazyHTML.from_document(html)

        assert count(doc, "#passkey-sign-in[phx-hook='PasskeySignIn'][phx-update='ignore']") == 1
        # Hidden on a CHILD of the ignored element, so a later patch cannot
        # restore what the hook removed.
        assert count(doc, "#passkey-sign-in > [data-role='passkey'][hidden]") == 1

        assert count(
                 doc,
                 "#passkey-sign-in [data-role='passkey'] button[type='button'][data-role='passkey-sign-in']"
               ) == 1

        assert count(doc, "#passkey-sign-in [data-role='passkey-status'][role='status']") == 1
      end

      assert render(lv) =~ "Use a passkey"
    end

    test "is translated with the page", %{conn: conn} do
      # The session preference the language switcher writes — what the auth
      # LiveViews' `:restore_locale` hook reads.
      html =
        conn
        |> unique_ip()
        |> init_test_session(%{"locale" => "es"})
        |> get(~p"/sign-in")
        |> html_response(200)

      assert html |> LazyHTML.from_document() |> count("html[lang='es']") == 1
      assert html =~ "Usar una clave de acceso"
    end

    test "is offered on /sign-in only, not on /register or /reset", %{conn: conn} do
      conn = unique_ip(conn)

      {:ok, lv, _html} = live(conn, ~p"/reset")
      refute has_element?(lv, "#passkey-sign-in")
    end
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()
end
