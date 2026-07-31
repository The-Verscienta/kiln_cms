defmodule KilnCMS.Newsletter.Validations.EmailAddress do
  @moduledoc """
  Rejects a subscriber address that the mail pipeline could not deliver to.

  `KilnCMS.Mail.enqueue!/1` *raises* `ArgumentError` on a malformed recipient
  (it guards DirectMX against MX-looking-up a garbage domain for hours). Since
  `:subscribe` now queues a confirmation email from an `after_action` hook, that
  raise would escape an anonymous public POST as a 500 — so the shape is checked
  as a validation, where it surfaces as an ordinary changeset error instead.

  Deliberately near-minimal — `local@domain` with no whitespace anywhere.
  Anything stricter starts rejecting addresses that are legal per RFC 5322 and
  that real people use. It is *strictly* tighter than the pipeline's own rule
  (which tolerates a space in the local part), so nothing that passes here can
  still trip the raise downstream.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:email)
    |> to_string()
    |> String.split("@")
    |> case do
      [local, domain] when local != "" and domain != "" ->
        if String.match?(local <> domain, ~r/\s/), do: error(), else: :ok

      _parts ->
        error()
    end
  end

  defp error do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :email,
       message: "is not a valid email address"
     )}
  end
end
