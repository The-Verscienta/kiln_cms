defmodule KilnCMS.CMS.Validations.SecurityTxt do
  @moduledoc """
  Validates a `KilnCMS.CMS.SiteSecurityTxt` row (#1873): every value is a
  single-line URI of a scheme RFC 9116 allows for its field, language tags are
  BCP 47-shaped, and a row with a contact has an `Expires` that has not passed.

  The single-line rule is the security-relevant one: the served file is
  `Field: value` lines, so a value carrying a CR, LF or any other line break
  would add a field the admin never wrote. The predicates live in
  `KilnCMS.SecurityTxt`, which applies them again when it renders.
  """
  use Ash.Resource.Validation

  alias KilnCMS.SecurityTxt

  @impl true
  def validate(changeset, _opts, _context) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    with :ok <- each(:contacts, get.(:contacts), &SecurityTxt.contact?/1, contact_message()),
         :ok <- one(:policy_url, get.(:policy_url), &SecurityTxt.https?/1, https_message()),
         :ok <-
           one(
             :acknowledgments_url,
             get.(:acknowledgments_url),
             &SecurityTxt.https?/1,
             https_message()
           ),
         :ok <-
           one(
             :encryption_url,
             get.(:encryption_url),
             &SecurityTxt.encryption?/1,
             encryption_message()
           ),
         :ok <-
           each(
             :preferred_languages,
             get.(:preferred_languages),
             &SecurityTxt.language_tag?/1,
             "must be language tags such as en or pt-BR"
           ) do
      expires(get.(:contacts), get.(:expires_on))
    end
  end

  @impl true
  def describe(_opts), do: [message: "must be valid security.txt values", vars: []]

  defp each(_field, nil, _valid?, _message), do: :ok

  defp each(field, values, valid?, message) when is_list(values) do
    case Enum.find(values, &(not valid?.(&1))) do
      nil -> :ok
      bad -> error(field, "#{inspect(bad)} #{message}")
    end
  end

  defp one(_field, nil, _valid?, _message), do: :ok

  defp one(field, value, valid?, message) do
    if valid?.(value), do: :ok, else: error(field, message)
  end

  # RFC 9116 makes `Expires` required, so a file with a contact must have one —
  # and a date already past would be served as a file researchers are told to
  # treat as stale.
  defp expires(contacts, expires_on) when contacts in [nil, []] and is_nil(expires_on), do: :ok
  defp expires(_contacts, nil), do: error(:expires_on, "is required when a contact is set")

  defp expires(_contacts, %Date{} = expires_on) do
    if Date.compare(expires_on, Date.utc_today()) == :lt,
      do: error(:expires_on, "must not be in the past"),
      else: :ok
  end

  defp contact_message,
    do: "must be one line: a mailto:, https:// or tel: address"

  defp https_message, do: "must be one line: an https:// URL"

  defp encryption_message,
    do: "must be one line: an https:// URL, an openpgp4fpr: fingerprint or a dns: URI"

  defp error(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
