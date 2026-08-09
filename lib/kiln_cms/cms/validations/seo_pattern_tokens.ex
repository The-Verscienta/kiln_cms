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

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- check(changeset, :seo_title_pattern) do
      check(changeset, :seo_description_pattern)
    end
  end

  defp check(changeset, field) do
    pattern = Ash.Changeset.get_attribute(changeset, field)

    with :ok <- Pattern.validate(pattern),
         :ok <- check_excerpt(changeset, pattern) do
      :ok
    else
      {:error, message} -> {:error, field: field, message: message}
    end
  end

  # `[excerpt]` on a type with no excerpt field is the same class of mistake as
  # `[titel]` — a token that can only ever expand to nothing — and it is the
  # likelier one, because the description input's placeholder suggests it and
  # the "Has an excerpt" checkbox sits right beside it. Caught here rather than
  # discovered in a search result.
  defp check_excerpt(changeset, pattern) do
    if Kiln.Tokens.uses?(pattern, "excerpt") and
         Ash.Changeset.get_attribute(changeset, :has_excerpt) != true do
      {:error, "[excerpt] needs this type to have an excerpt — tick \"Has an excerpt\" first"}
    else
      :ok
    end
  end
end
