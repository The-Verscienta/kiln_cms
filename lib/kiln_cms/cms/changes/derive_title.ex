defmodule KilnCMS.CMS.Changes.DeriveTitle do
  @moduledoc """
  Writes a record's `title` from its type's `title_template` (#2287).

  A type with a template owns its titles: whatever title the caller supplied is
  overwritten (the API accepts the input rather than erroring, so a client
  written before the template existed keeps working). The template reads the
  record's custom fields, as the write will store them (`Titles`), and runs
  **before** `DeriveSlug` — the slug follows the derived title — and before
  `ApplyCustomFields`, so a computed field that reads `title` sees it.

  A template that yields nothing (every field it reads is empty) derives
  nothing, and the changeset is left alone: a create keeps the title it was
  given (the editor's "Untitled" scaffold) or fails the usual required check,
  an update keeps the title the record has.

  Declared on `:create`, `:update` and `:autosave`. On `:save_working_copy`
  (`target: :working_title`) it writes the working title from the working
  copy's own fields, ahead of `StampWorkingCopy`, so a live page's title does
  not move until *Publish changes*; `PromoteWorkingCopy` derives once more
  from the promoted fields. It deliberately is not on the publish transition or
  on a version restore, which put back what the record held.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Titles

  @impl true
  def change(changeset, opts, _context) do
    case Keyword.get(opts, :target, :title) do
      :working_title -> derive(changeset, :working_title, working_fields(changeset))
      :title -> changeset |> run(:title, nil) |> release_scaffold_slug()
    end
  end

  # The editor creates a draft with an `untitled-…` scaffold slug and relies on
  # the writer's typing to replace it. A template-derived title is never typed,
  # so without this the slug would stay the scaffold for good. A scaffold slug
  # is cleared when the title it was waiting for arrives, and `DeriveSlug`
  # (declared next) derives the real one. Any other slug — a published page's
  # included — is left exactly as it is: editing a source field never moves a URL.
  defp release_scaffold_slug({false, changeset}), do: changeset

  defp release_scaffold_slug({true, changeset}) do
    slug = Ash.Changeset.get_attribute(changeset, :slug)

    if is_binary(slug) and KilnCMS.CMS.Slugs.underived?(slug, "") and
         KilnCMS.Slug.derive(Ash.Changeset.get_attribute(changeset, :title)) != "" do
      Ash.Changeset.force_change_attribute(changeset, :slug, nil)
    else
      changeset
    end
  end

  @doc """
  Derive into `target` (`:title` or `:working_title`). `custom_fields`, when a
  map, is the field set to read instead of the stored map with the payload
  merged over it — the working copy's, or the ones a promotion just wrote.
  """
  @spec derive(Ash.Changeset.t(), :title | :working_title, map() | nil) :: Ash.Changeset.t()
  def derive(changeset, target, custom_fields) do
    {_derived?, changeset} = run(changeset, target, custom_fields)
    changeset
  end

  # `{derived?, changeset}`: whether a template wrote the title.
  defp run(changeset, target, custom_fields) do
    {template, changeset} = Titles.template_for(changeset)

    with template when is_binary(template) <- template,
         context = Titles.changeset_context(changeset, template, custom_fields),
         {:ok, title} <- Titles.derive(template, context) do
      {true, Ash.Changeset.force_change_attribute(changeset, target, title)}
    else
      _no_template_or_blank -> {false, changeset}
    end
  end

  # What the working copy will hold once this save lands: the held
  # `custom_fields` (staged by `StageWorkingFields`, declared before this) when
  # the copy has diverged on them, else the live map.
  defp working_fields(changeset) do
    held = Ash.Changeset.get_attribute(changeset, :working_fields) || %{}
    Map.get(held, "custom_fields") || changeset.data.custom_fields || %{}
  end
end
