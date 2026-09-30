defmodule KilnCMSWeb.ContentEditor.InlineTerms do
  @moduledoc """
  Create a tag or a category from inside the content editor (#1805), without a
  trip to the Taxonomy page.

  The editor only ever *selects* the result — it ticks the tag, or sets the
  category select — so the term reaches the entry the same way a picked one
  does: through the form, the draft autosave and Save. Only the taxonomy row
  itself is written here, immediately, through the `KilnCMS.CMS` code
  interfaces with the editor as actor and the site as tenant, so the Taxonomy
  policies decide exactly as they do on the Taxonomy page.

  Typing a name that already exists is not an error an author can do anything
  about, so it resolves to the existing term instead (case-insensitively). A
  name whose slug is already taken by a *different* name ("C++" and "C" both
  slugify to `c`) gets a suffixed slug rather than a validation error about a
  field the editor never saw.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  import Ash.Expr

  alias KilnCMS.CMS

  @type kind :: :tag | :category

  @doc "Whether `actor` may create a term of `kind` on `org` — the UI gate."
  @spec can_create?(kind(), term(), term()) :: boolean()
  def can_create?(_kind, nil, _org), do: false
  def can_create?(:tag, actor, org), do: CMS.can_create_tag?(actor, %{}, tenant: org)

  def can_create?(:category, actor, org),
    do: CMS.can_create_category?(actor, %{}, tenant: org)

  @doc """
  Resolve `name` to a term of `kind`: the existing one with that name, or a new
  one. `:ignore` for a blank name; `{:error, message}` with a sentence the
  editor can read when the write is refused.
  """
  @spec find_or_create(kind(), term(), term(), term()) ::
          {:ok, struct(), :existing | :created} | {:error, String.t()} | :ignore
  def find_or_create(kind, name, actor, org) do
    case normalize(name) do
      "" ->
        :ignore

      name ->
        case find_by_name(kind, name, actor, org) do
          %{} = term -> {:ok, term, :existing}
          nil -> create(kind, name, actor, org)
        end
    end
  end

  defp normalize(name) when is_binary(name), do: String.trim(name)
  defp normalize(_name), do: ""

  defp find_by_name(kind, name, actor, org) do
    wanted = String.downcase(name)

    kind
    |> list(
      actor: actor,
      tenant: org,
      query: [filter: expr(string_downcase(name) == ^wanted), limit: 1]
    )
    |> List.first()
  end

  defp create(kind, name, actor, org) do
    slug = KilnCMS.Slug.taxonomy_slug(name)

    slug =
      if slug_taken?(kind, slug, actor, org),
        do: slug <> "-" <> KilnCMS.Slug.random_suffix(),
        else: slug

    case write(kind, %{name: name, slug: slug}, actor: actor, tenant: org) do
      {:ok, term} -> {:ok, term, :created}
      {:error, error} -> {:error, error_message(kind, error)}
    end
  end

  defp slug_taken?(kind, slug, actor, org) do
    match?({:ok, %{}}, by_slug(kind, slug, actor: actor, tenant: org, not_found_error?: false))
  end

  defp list(:tag, opts), do: CMS.list_tags!(opts)
  defp list(:category, opts), do: CMS.list_categories!(opts)

  defp by_slug(:tag, slug, opts), do: CMS.get_tag_by_slug(slug, opts)
  defp by_slug(:category, slug, opts), do: CMS.get_category_by_slug(slug, opts)

  defp write(:tag, attrs, opts), do: CMS.create_tag(attrs, opts)
  defp write(:category, attrs, opts), do: CMS.create_category(attrs, opts)

  defp error_message(:tag, error) do
    KilnCMSWeb.CoreComponents.ash_error_message(error,
      forbidden: gettext("You don't have permission to add tags."),
      fallback: gettext("Couldn't add that tag.")
    )
  end

  defp error_message(:category, error) do
    KilnCMSWeb.CoreComponents.ash_error_message(error,
      forbidden: gettext("You don't have permission to add categories."),
      fallback: gettext("Couldn't add that category.")
    )
  end
end
