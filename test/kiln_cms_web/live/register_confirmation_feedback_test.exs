defmodule KilnCMSWeb.RegisterConfirmationFeedbackTest do
  @moduledoc """
  The register form reports a mismatched password confirmation while it is
  being typed, not only after a submit.

  `KilnCMSWeb.AuthRegisterForm` is the seam: upstream validates the change
  event with `errors: false`, which held back every error — the two password
  boxes disagreeing included — until the round trip through the register
  action. These tests pin both halves of the narrow fix: the confirmation
  error shows on `phx-change`, and nothing *else* does.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @form "#user-password-register-with-password-wrapper form"
  @password "password123456"

  # The message `AshAuthentication.Strategy.Password.PasswordConfirmationValidation`
  # raises, rendered under the confirmation field.
  @mismatch "does not match"

  defp change(view, params) do
    view
    |> form(@form, user: params)
    |> render_change()
  end

  defp email, do: "register-confirm-#{System.unique_integer([:positive])}@example.com"

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")
    %{view: view}
  end

  test "a confirmation that disagrees with the password is reported on change", %{view: view} do
    html =
      change(view, %{
        email: email(),
        password: @password,
        password_confirmation: @password <> "-typo"
      })

    assert html =~ @mismatch
  end

  test "a matching confirmation reports nothing", %{view: view} do
    html =
      change(view, %{email: email(), password: @password, password_confirmation: @password})

    refute html =~ @mismatch
  end

  test "an untouched confirmation box is not yet a mismatch", %{view: view} do
    # Typing the password alone makes password != confirmation, and saying so
    # before the visitor has reached the second box would be noise.
    html = change(view, %{email: email(), password: @password, password_confirmation: ""})

    refute html =~ @mismatch
  end

  test "the other fields stay quiet while typing", %{view: view} do
    # The reason upstream disables errors on change in the first place: with
    # them on wholesale, an empty email field answers back on the first
    # keystroke elsewhere. Only the confirmation is revealed early.
    html = change(view, %{email: "", password: @password, password_confirmation: @password})

    refute html =~ "is required"
  end

  test "a mismatch still fails the submit", %{view: view} do
    # The early feedback is display-only: the change handler narrows what the
    # form shows, and must not narrow what the action enforces.
    html =
      view
      |> form(@form, user: %{email: email(), password: @password, password_confirmation: "nope"})
      |> render_submit()

    assert html =~ @mismatch
  end
end
