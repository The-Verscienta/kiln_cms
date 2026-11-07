defmodule KilnCMS.CMS.FieldTypes.Slug do
  @moduledoc """
  A **slug** custom field (#2278): lowercase words joined by hyphens, as in
  `field-types-2278`.

  Typed text goes through `KilnCMS.Slug.slugify/1`, so `"Café Menu!"` is stored
  as `"cafe-menu"` and slugifying an already-valid slug changes nothing. Input
  with nothing left after that (only punctuation, or a script `slugify/1`
  transliterates away, such as Chinese) is refused rather than stored empty.

  The value is **not unique**: two records may hold the same slug. Uniqueness
  across a content type is a separate concern. To derive one from another
  field, use a `:computed` field.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_length 128

  @impl Kiln.FieldType
  def label, do: "Slug"

  @impl Kiln.FieldType
  def description do
    gettext(
      "URL-safe words joined by hyphens; what you type is tidied up. For a short code or a path segment. Not checked for uniqueness."
    )
  end

  @impl Kiln.FieldType
  def input_attrs(_definition) do
    %{pattern: "[a-z0-9]+(-[a-z0-9]+)*", maxlength: @max_length, placeholder: "my-page"}
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :string

  @impl Kiln.FieldType
  def json_schema(_definition),
    do: %{"type" => ["string", "null"], "pattern" => "^[a-z0-9]+(-[a-z0-9]+)*$"}

  @impl Kiln.FieldType
  # The byte bound runs first so a megabyte of text never reaches the transliteration.
  def cast(value, _definition) when is_binary(value) and byte_size(value) <= @max_length * 8 do
    with true <- String.valid?(value),
         slug when slug != "" <- KilnCMS.Slug.slugify(value),
         true <- String.length(slug) <= @max_length do
      {:ok, slug}
    else
      _ -> {:error, message()}
    end
  end

  def cast(_value, _definition), do: {:error, message()}

  defp message,
    do:
      "must contain letters or digits, and be at most #{@max_length} characters once made URL-safe"
end
