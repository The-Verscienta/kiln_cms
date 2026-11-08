defmodule KilnCMS.Accounts.Validations.InvitationEmail do
  @moduledoc """
  An invitation's address must be one `KilnCMS.Mail.enqueue!/2` will accept
  (#2135): trimmed (the `:ci_string` cast does that), at most 254 characters
  (the SMTP path limit), exactly one `@` with something on both sides, and no
  space in the domain.

  The mail is enqueued in the same transaction as the row, and `enqueue!/2`
  raises `ArgumentError` on an address it refuses. Without this a typo in the
  Team page's form would crash the page instead of reading as a form error.
  """
  use Ash.Resource.Validation

  @max_length 254

  @impl true
  def validate(changeset, _opts, _context) do
    address = changeset |> Ash.Changeset.get_attribute(:email) |> to_text()

    if String.length(address) <= @max_length and KilnCMS.Mail.valid_address?(address) do
      :ok
    else
      {:error, field: :email, message: "must be a valid email address"}
    end
  end

  defp to_text(nil), do: ""
  defp to_text(value), do: value |> to_string() |> String.trim()
end
