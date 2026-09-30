defmodule KilnCMSWeb.PasswordRevealTest do
  @moduledoc """
  The eye button beside every password box on the sign-in, register and reset
  pages (#1806) — and on the change-password form, via `<.input reveal>`.

  What LiveViewTest can hold: the button is server-rendered on each page, is a
  `type="button"` (it must never submit), names the box it controls, starts
  unpressed with a "Show password" label, and carries the JS command that does
  the flipping. That the click flips the box, and that the flip survives a
  LiveView patch, is the browser's half — `e2e/tests/password_reveal.spec.js`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  describe "the auth pages" do
    test "sign-in has one toggle, on its password box", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sign-in")

      assert [_] = toggles_in(html, "form[action='/auth/user/password/sign_in']")
    end

    test "register has one on each of its two password boxes", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register")

      assert [_, _] = toggles_in(html, "#user-password-register-with-password-wrapper form")
    end

    test "the new-password form behind a reset link has one on each box", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/password-reset/not-a-real-token")

      assert [_, _] = toggles_in(html, "form[action='/auth/user/password/reset']")
    end

    test "the boxes keep their styling and gain room for the button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sign-in")

      [class] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("form[action='/auth/user/password/sign_in'] input[type=password]")
        |> LazyHTML.attribute("class")

      assert class =~ "field-input"
      assert class =~ "pr-10"
    end

    test "survive a validation round trip still pointing at their box", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#user-password-register-with-password-wrapper form",
          user: %{email: "someone@example.com", password: "abc", password_confirmation: "abd"}
        )
        |> render_change()

      assert html =~ "does not match"
      assert [_, _] = toggles_in(html, "#user-password-register-with-password-wrapper form")
    end
  end

  describe "the change-password form" do
    test "has a toggle on all three boxes, autocomplete intact", %{conn: conn} do
      {:ok, _view, html} = conn |> log_in(authed_user()) |> live(~p"/editor/settings")

      assert [_, _, _] = toggles_in(html, "#password-form")

      autocomplete =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#password-form input[type=password]")
        |> LazyHTML.attribute("autocomplete")

      assert autocomplete == ["current-password", "new-password", "new-password"]
    end
  end

  describe "<.input type=\"password\" reveal>" do
    test "needs an id to point the toggle at" do
      assert_raise ArgumentError, ~r/needs an id/, fn ->
        render_component(&KilnCMSWeb.CoreComponents.input/1,
          type: "password",
          name: "pw",
          value: nil,
          reveal: true
        )
      end
    end

    test "is a plain password box without it" do
      html =
        render_component(&KilnCMSWeb.CoreComponents.input/1,
          type: "password",
          id: "pw",
          name: "pw",
          value: nil
        )

      refute html =~ "data-password-reveal"
    end
  end

  # Every toggle inside `scope`, each checked against the contract: a
  # non-submitting button, pointed (by id) at a password box in the same form,
  # starting unpressed and labelled for what a press will do, with the JS
  # command that flips the box's type. Returns the toggles' `aria-controls`.
  defp toggles_in(html, scope) do
    doc = LazyHTML.from_document(html)
    buttons = LazyHTML.query(doc, scope <> " button[data-password-reveal]")

    Enum.map(buttons, fn button ->
      [target] = LazyHTML.attribute(button, "aria-controls")

      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "aria-pressed") == ["false"]
      assert LazyHTML.attribute(button, "aria-label") == ["Show password"]
      assert LazyHTML.attribute(button, "id") == [target <> "-reveal"]

      assert doc
             |> LazyHTML.query(~s(#{scope} input[type=password][id="#{target}"]))
             |> Enum.count() ==
               1

      assert button |> LazyHTML.query(".hero-eye") |> Enum.count() == 1
      assert button |> LazyHTML.query(".hero-eye-slash") |> Enum.count() == 1

      [click] = LazyHTML.attribute(button, "phx-click")
      ops = Jason.decode!(click)

      assert ["toggle_attr", %{"attr" => ["type", "password", "text"], "to" => "#" <> ^target}] in ops
      assert ["toggle_attr", %{"attr" => ["aria-pressed", "false", "true"]}] in ops
      assert ["toggle_attr", %{"attr" => ["aria-label", "Show password", "Hide password"]}] in ops

      target
    end)
  end

  defp authed_user do
    email = "password-reveal-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
