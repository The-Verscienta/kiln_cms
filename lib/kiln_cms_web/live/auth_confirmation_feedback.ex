defmodule KilnCMSWeb.AuthConfirmationFeedback do
  @moduledoc """
  Reveals "does not match" under the second password box as it is typed, on the
  AshAuthentication forms that have two.

  ## The behaviour this changes

  Both password forms with a confirmation field — register, and the new password
  behind a reset link — handle their `"change"` event the same way upstream:

      socket.assigns.form |> Form.validate(params, errors: false)

  Suppressing errors is the right default for the form as a whole. With them on,
  "is required" appears under the email field on the first keystroke of it,
  before the visitor has had a chance to be wrong, and on the reset page an
  invalid-token error would answer a question nobody asked. But it also holds
  back the one mistake the visitor *has* already made and can already see: two
  password boxes that do not agree. That surfaced only after a submit round
  trip, which on the register form also clears the password field — so a typo in
  the confirmation cost re-typing both.

  ## What is revealed, and what is not

  `validate_change/3` still validates with `errors: false`. It then re-marks the
  form as displaying errors with every error *except* the ones on the
  confirmation field filtered out, and only once that box has been typed into —
  an empty second box is someone who has not reached it yet, not a mismatch.
  Every other field stays quiet until submit, exactly as before, and submit
  still reports everything.

  ## Why writing to the form struct is the right seam

  `Form.validate(errors: false)` has already run every validation, the
  confirmation check among them, and only suppressed the display
  (`AshPhoenix.Form.validate/3` sets `errors: !!opts[:errors]`, and
  `Form.errors/1` returns `[]` while that is false). So this does not re-derive
  the mismatch in Kiln — it takes the error the changeset already holds and
  narrows what the form is willing to show to that one field.

  Both fields written here are the documented way in. `AshPhoenix.Form.add_error/3`
  says outright that the form's `errors` field has to be true for an error to be
  visible, and the source's error list is what `Form.errors/1` reads through the
  form's `transform_errors`. The narrowed list does not have to survive anything:
  `"change"` and `"submit"` both rebuild the changeset from the action and the
  params, so what is dropped here is recomputed on the next event rather than
  lost — which is also why this cannot weaken what the action enforces.

  ## Users

  `KilnCMSWeb.AuthRegisterForm` and `KilnCMSWeb.AuthResetForm`, each of which
  wraps the library component it replaces and delegates everything else to it.
  """

  alias AshPhoenix.Form

  @doc """
  Validates a `"change"` payload from one of the password forms, with the
  confirmation field's errors — and only those — revealed.

  `params` is the raw event payload, `form` the component's `AshPhoenix.Form`
  and `strategy` its `AshAuthentication` password strategy.
  """
  @spec validate_change(Form.t(), map, struct) :: Form.t()
  def validate_change(form, params, strategy) do
    params = strategy_params(params, form)

    form
    |> Form.validate(params, errors: false)
    |> reveal_confirmation_error(params, strategy)
  end

  # Upstream's private `get_params/2` rebuilds this key by slugifying the
  # subject name. `form.name` is the same string arrived at from the other end:
  # it is the `as:` the form was built with, and so the key the browser posts
  # under.
  defp strategy_params(params, form), do: Map.get(params, form.name, %{})

  defp reveal_confirmation_error(form, params, strategy) do
    field = strategy.password_confirmation_field
    errors = Enum.filter(form.source.errors, &(Map.get(&1, :field) == field))

    if errors == [] or not typed?(Map.get(params, to_string(field))) do
      form
    else
      %{form | errors: true, source: %{form.source | errors: errors}}
    end
  end

  # Deliberately not trimmed: whitespace is a legitimate password character, so
  # " " is something they typed.
  defp typed?(value) when is_binary(value), do: value != ""
  defp typed?(_value), do: false
end
