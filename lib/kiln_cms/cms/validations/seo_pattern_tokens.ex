defmodule KilnCMS.CMS.Validations.SeoPatternTokens do
  @moduledoc """
  Rejects a `seo_title_pattern` or `seo_description_pattern` with unknown
  tokens (#805), so a typo like `[titel]` fails at save time instead of
  silently expanding to nothing on every page of that type.

  The sibling of `KilnCMS.CMS.Validations.SlugPatternTokens`, and deliberately
  simpler: the SEO vocabulary admits no field-type-declared tokens (see
  `KilnCMS.Seo.Pattern`), so there is no field-definition read here and the
  ordering constraint that module documents does not arise.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Seo.Pattern

  @fields [:seo_title_pattern, :seo_description_pattern]

  @impl true
  def validate(changeset, _opts, _context) do
    Enum.reduce_while(@fields, :ok, fn field, :ok ->
      case Pattern.validate(Ash.Changeset.get_attribute(changeset, field)) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, field: field, message: message}}
      end
    end)
  end
end
