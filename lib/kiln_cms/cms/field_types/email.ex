defmodule KilnCMS.CMS.FieldTypes.Email do
  @moduledoc """
  An **email** custom field (#2278): one address, checked for shape and stored
  with its domain lowercased.

  The check is deliberately modest: trimmed, at most 254 bytes (64 before the
  `@`), exactly one `@`, a dotted domain whose labels are letters, digits and
  hyphens, and no spaces or control characters. It says "this is plausibly an
  address", not "this mailbox exists". It is hand-rolled over the string rather
  than one regular expression, so no input can make it backtrack.

  The local part keeps its case (mailbox names may be case-sensitive); only the
  domain is lowercased, so `Ada@Example.COM` is stored as `Ada@example.com`.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_total 254
  @max_local 64
  @max_label 63

  # Not allowed in the local part: whitespace and control characters (checked
  # separately), the `@` itself, and the RFC 5322 specials that need quoting.
  @local_forbidden ~c"@<>()[]\\,;:\""

  @impl Kiln.FieldType
  def label, do: "Email address"

  @impl Kiln.FieldType
  def description do
    gettext(
      "One email address, checked for shape. For a contact, an author or a booking address."
    )
  end

  @impl Kiln.FieldType
  def input_type, do: "email"

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :string

  @impl Kiln.FieldType
  def json_schema(_definition), do: %{"type" => ["string", "null"], "format" => "email"}

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- String.valid?(trimmed) and byte_size(trimmed) <= @max_total,
         [local, domain] <- String.split(trimmed, "@"),
         true <- local_ok?(local),
         domain = String.downcase(domain),
         true <- domain_ok?(domain) do
      {:ok, local <> "@" <> domain}
    else
      _ -> {:error, message()}
    end
  end

  def cast(_value, _definition), do: {:error, message()}

  defp local_ok?(local) do
    byte_size(local) in 1..@max_local//1 and
      not String.starts_with?(local, ".") and
      not String.ends_with?(local, ".") and
      not String.contains?(local, "..") and
      local |> String.to_charlist() |> Enum.all?(&local_char?/1)
  end

  defp local_char?(char),
    do: char > 32 and char not in @local_forbidden and not invisible?(char)

  # Whitespace, control and format characters of any script (no-break space,
  # line separator, zero-width space, bidi marks): invisible in an address.
  defp invisible?(char), do: Regex.match?(~r/\A[\p{Z}\p{Cc}\p{Cf}]\z/u, <<char::utf8>>)

  defp domain_ok?(domain) do
    labels = String.split(domain, ".")
    length(labels) >= 2 and Enum.all?(labels, &label_ok?/1)
  end

  defp label_ok?(label) do
    byte_size(label) in 1..@max_label//1 and
      not String.starts_with?(label, "-") and
      not String.ends_with?(label, "-") and
      label |> String.to_charlist() |> Enum.all?(&label_char?/1)
  end

  # Letters and digits of any script (internationalised domains), and hyphens.
  defp label_char?(?-), do: true
  defp label_char?(char) when char < 128, do: char in ?a..?z or char in ?0..?9
  defp label_char?(char), do: Regex.match?(~r/\A[\p{L}\p{N}]\z/u, <<char::utf8>>)

  defp message, do: "must be an email address (e.g. name@example.com)"
end
