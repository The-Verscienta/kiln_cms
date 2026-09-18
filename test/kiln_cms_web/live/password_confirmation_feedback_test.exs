defmodule KilnCMSWeb.PasswordConfirmationFeedbackTest do
  @moduledoc """
  Both forms with two password boxes report a mismatch while it is being typed,
  not only after a submit.

  `KilnCMSWeb.AuthConfirmationFeedback` is the seam: upstream validates the
  change event with `errors: false`, which held back every error — the two boxes
  disagreeing included — until the round trip through the action. These tests
  pin both halves of the narrow fix on each page: the confirmation error shows
  on `phx-change`, and nothing *else* does.

  The two pages reach it differently. `/register` swaps one component through
  the library's `register_form_module` override; `/password-reset/:token` has no
  such hook, so it is re-pointed a component at a time from `KilnCMSWeb.ResetLive`
  down. That is the more fragile of the two — three modules rather than one —
  which is why the reset cases below also assert that the page still renders its
  own furniture.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @register_form "#user-password-register-with-password-wrapper form"
  # Upstream renders this form without an id (`<.form for={@form}>` with no
  # `id:`), so it is addressed by its POST target, the way the magic-link form
  # is in `KilnCMSWeb.SignInRateLimitTest`.
  @reset_form ~s(form[action="/auth/user/password/reset"])
  @password "password123456"

  # The message `AshAuthentication.Strategy.Password.PasswordConfirmationValidation`
  # raises, rendered under the confirmation field.
  @mismatch "does not match"

  defp change(view, selector, params) do
    view
    |> form(selector, user: params)
    |> render_change()
  end

  defp email, do: "confirm-feedback-#{System.unique_integer([:positive])}@example.com"

  describe "the register form" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")
      %{view: view}
    end

    test "reports a confirmation that disagrees with the password on change", %{view: view} do
      html =
        change(view, @register_form, %{
          email: email(),
          password: @password,
          password_confirmation: @password <> "-typo"
        })

      assert html =~ @mismatch
    end

    test "reports nothing when the confirmation matches", %{view: view} do
      html =
        change(view, @register_form, %{
          email: email(),
          password: @password,
          password_confirmation: @password
        })

      refute html =~ @mismatch
    end

    test "does not call an untouched confirmation box a mismatch", %{view: view} do
      # Typing the password alone makes password != confirmation, and saying so
      # before the visitor has reached the second box would be noise.
      html =
        change(view, @register_form, %{
          email: email(),
          password: @password,
          password_confirmation: ""
        })

      refute html =~ @mismatch
    end

    test "leaves the other fields quiet while typing", %{view: view} do
      # The reason upstream disables errors on change in the first place: with
      # them on wholesale, an empty email field answers back on the first
      # keystroke elsewhere. Only the confirmation is revealed early.
      html =
        change(view, @register_form, %{
          email: "",
          password: @password,
          password_confirmation: @password
        })

      refute html =~ "is required"
    end

    test "still fails the submit on a mismatch", %{view: view} do
      # The early feedback is display-only: the change handler narrows what the
      # form shows, and must not narrow what the action enforces.
      html =
        view
        |> form(@register_form,
          user: %{email: email(), password: @password, password_confirmation: "nope"}
        )
        |> render_submit()

      assert html =~ @mismatch
    end
  end

  describe "the reset form" do
    setup %{conn: conn} do
      # The token is carried in a hidden field and only checked by the action,
      # so the page renders its form for any token. `ResetTokenValidation`
      # failing on this one is the point of the last test in this block.
      {:ok, view, html} = live(conn, ~p"/password-reset/not-a-real-token")
      %{view: view, html: html}
    end

    test "renders Kiln's form component in place of the library's", %{html: html} do
      # The chain re-pointed here is three modules deep and copies two renders,
      # so this asserts the page still arrives: the form, and the classes
      # `override Components.Reset.Form` sets on it through the copies.
      assert html =~ ~s(id="user-password-reset-password-with-token_password_confirmation")
      # From `override Components.Reset.Form` — proof the copied renders still
      # read the settings written for the components they stand in for.
      assert html =~ ~s(phx-disable-with="Changing password ...")
    end

    test "reports a confirmation that disagrees with the password on change", %{view: view} do
      html =
        change(view, @reset_form, %{password: @password, password_confirmation: @password <> "!"})

      assert html =~ @mismatch
    end

    test "reports nothing when the confirmation matches", %{view: view} do
      html = change(view, @reset_form, %{password: @password, password_confirmation: @password})

      refute html =~ @mismatch
    end

    test "does not call an untouched confirmation box a mismatch", %{view: view} do
      html = change(view, @reset_form, %{password: @password, password_confirmation: ""})

      refute html =~ @mismatch
    end

    test "leaves the token's own error for the submit", %{view: view} do
      # A bad reset token is not the visitor's typing and must not answer back
      # mid-form — narrowing the change event to the confirmation field is what
      # keeps `ResetTokenValidation` quiet until they submit.
      html =
        change(view, @reset_form, %{password: @password, password_confirmation: @password <> "!"})

      assert html =~ @mismatch
      refute html =~ "is invalid"
    end
  end
end
