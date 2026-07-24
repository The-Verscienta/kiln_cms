defmodule KilnCMS.CMS.Validations.SlugPatternTokens do
  @moduledoc """
  Rejects a `slug_pattern` or `alias_pattern` with unknown tokens (see
  `KilnCMS.Slug.Pattern`), so a typo like `[titel]` fails at save time
  instead of silently expanding to nothing on every entry. Alias patterns
  additionally admit the `[slug]` token (circular in a slug pattern).
  """
  use Ash.Resource.Validation

  alias KilnCMS.Slug.Pattern

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- check(changeset, :slug_pattern, usage: :slug) do
      check(changeset, :alias_pattern, usage: :alias)
    end
  end

  defp check(changeset, field, opts) do
    case Pattern.validate(Ash.Changeset.get_attribute(changeset, field), opts) do
      :ok -> :ok
      {:error, message} -> {:error, field: field, message: message}
    end
  end
end
