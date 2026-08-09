defmodule KilnCMS.CMS.Validations.SlugPatternTokens do
  @moduledoc """
  Rejects a `slug_pattern` or `alias_pattern` with unknown tokens (see
  `KilnCMS.Slug.Pattern`), so a typo like `[titel]` fails at save time
  instead of silently expanding to nothing on every entry. Alias patterns
  additionally admit the `[slug]` token (circular in a slug pattern).

  ## Tokens a field type declares (#804)

  A custom field type can contribute its own tokens through
  `c:Kiln.FieldType.tokens/1` — a composite's named parts, or a derived form.
  Those are as legitimate here as `[title]`, so the vocabulary this validates
  against includes them, read off the field definitions already attached to the
  type being saved.

  The lookup is skipped entirely unless the pattern mentions something the
  built-ins do not cover, which is almost every pattern.

  **Order matters for the operator, and cannot be fixed here.** The field has to
  exist before a pattern may name its token: setting the pattern first is
  rejected, because at that moment nothing in the system claims that token and
  "unknown token" is the truthful answer. Adding the field then re-saving the
  pattern works. The alternative — accepting any unrecognised token in case a
  field appears later — is how `[titel]` gets into production.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.Slugs
  alias KilnCMS.Slug.Pattern

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- check(changeset, :slug_pattern, :slug) do
      check(changeset, :alias_pattern, :alias)
    end
  end

  defp check(changeset, field, usage) do
    pattern = Ash.Changeset.get_attribute(changeset, field)
    opts = [usage: usage, extra_definitions: extra_definitions(changeset, pattern, usage)]

    case Pattern.validate(pattern, opts) do
      :ok -> :ok
      {:error, message} -> {:error, field: field, message: message}
    end
  end

  # Only when the built-ins come up short — see the moduledoc. On a CREATE the
  # type has no field definitions yet, so this is an empty read; that is the
  # ordering constraint stated above rather than something to work around.
  defp extra_definitions(changeset, pattern, usage) do
    case Pattern.unknown_tokens(pattern, usage) do
      [] -> []
      _unknown -> changeset |> type_field_definitions() |> Slugs.type_token_definitions()
    end
  end

  defp type_field_definitions(changeset) do
    case Ash.Changeset.get_data(changeset, :id) do
      nil ->
        []

      id ->
        KilnCMS.CMS.field_definitions_for_definition!(id,
          authorize?: false,
          tenant: changeset.to_tenant
        )
    end
  rescue
    # A validation must not turn a missing/unreadable definition set into a 500
    # on a settings save — the pattern is simply validated against the built-ins.
    _error -> []
  end
end
