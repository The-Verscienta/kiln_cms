defmodule KilnCMS.CMS.Validations.SlugPatternTokens do
  @moduledoc """
  Rejects a `slug_pattern` with unknown tokens (see `KilnCMS.Slug.Pattern`),
  so a typo like `[titel]` fails at save time instead of silently expanding
  to nothing on every entry.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case KilnCMS.Slug.Pattern.validate(Ash.Changeset.get_attribute(changeset, :slug_pattern)) do
      :ok -> :ok
      {:error, message} -> {:error, field: :slug_pattern, message: message}
    end
  end
end
