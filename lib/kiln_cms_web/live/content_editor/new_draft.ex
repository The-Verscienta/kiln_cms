defmodule KilnCMSWeb.ContentEditor.NewDraft do
  @moduledoc """
  Who may start a new document of a type, and the row a new document becomes.

  "New page" used to create that row on the click, so every abandoned click
  left an "Untitled page" behind for `:sweep_untitled` to trash a week later.
  The editor now opens unsaved at `/editor/content/:type/new` and calls
  `create/3` on the writer's first commit — a non-blank title, or Save — then
  carries on in place (see `KilnCMSWeb.ContentEditorLive`).

  Both halves live here so the content list's New buttons, the `/new` mount
  and the create cannot disagree about who may author what or what a fresh
  draft looks like.
  """

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.EditorialSettings
  alias KilnCMS.Slug

  @doc """
  Whether `actor` may create content of `content_type` (a `ContentTypes`
  descriptor) in `org_id`. The same question the create policy asks
  (`Checks.EditableContentType`), so the button and the action cannot disagree.
  """
  def may_author?(actor, org_id, content_type) do
    case Scoping.effective_tier(actor, org_id) do
      :admin ->
        true

      :editor ->
        Scoping.permitted?(actor, org_id, :editable_types, type_name_of(content_type))

      _ ->
        false
    end
  end

  @doc """
  Every content type `actor` may start a new document of in `org` — the site's
  types filtered by `may_author?/3`. The content list's New buttons and the
  calendar's "new on this day" picker both offer exactly this list.
  """
  def authorable_types(actor, org) do
    org_id = KilnCMS.Accounts.org_id(org)

    org
    |> ContentTypes.all_for_org()
    |> Enum.filter(&may_author?(actor, org_id, &1))
  end

  @doc """
  Whether `actor` may give a new document a publish date in `org_id`.

  A publish date IS a publish — the content policy gates `scheduled_at` like
  Publish — so this is an admin, or an editor on a site that lets editors
  publish. The editor's own schedule field asks the same question.
  """
  def may_schedule?(actor, org_id) do
    case Scoping.effective_tier(actor, org_id) do
      :admin -> true
      :editor -> EditorialSettings.editors_can_publish?(org_id)
      _ -> false
    end
  end

  @doc """
  The publish date a `/new?scheduled_at=` link asks for, or `nil`.

  Accepts an ISO 8601 timestamp with an offset (the calendar sends UTC, `Z`).
  Anything else — garbage, a bare date, a time already past — is `nil`, so a
  stale or hand-edited link opens an ordinary unscheduled draft rather than
  failing.
  """
  @spec parse_scheduled_at(term()) :: DateTime.t() | nil
  def parse_scheduled_at(value) when is_binary(value) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(value),
         true <- DateTime.after?(at, DateTime.utc_now()) do
      DateTime.truncate(at, :second)
    else
      _ -> nil
    end
  end

  def parse_scheduled_at(_value), do: nil

  # `editable_types` groups every dynamic type under `entry` (see
  # docs/granular-rbac.md) — deliberately, unlike field grants.
  defp type_name_of(%{source: :dynamic}), do: "entry"
  defp type_name_of(%{type: type}), do: to_string(type)

  @doc """
  Create the draft row: the scaffold title and slug the New button has always
  used, through the type's own create action with the writer as actor and the
  site as tenant — so authorization, per-type defaults and slug handling are
  exactly what they were when the click did this.

  `extra` carries what the link that opened the editor asked for — today only
  a `scheduled_at` from the calendar (see `parse_scheduled_at/1`).

  The title is the scaffold on purpose. The writer's own title arrives through
  the editor's normal `validate` right after, which re-derives the slug from it
  (an `untitled-…` slug counts as underived) and autosaves — a title that fails
  validation then shows as a field error instead of refusing the create.
  """
  def create(kind, actor, org, extra \\ %{}) do
    scaffold = %{
      title: "Untitled #{kind}",
      # NOT `System.unique_integer/1` (#834): that counter resets on every VM
      # start, while the `untitled-N` rows it must miss live in Postgres and
      # outlive any restart — so a fresh node re-issues low numbers and the
      # create fails with "slug has already been taken", leaving the button
      # doing nothing.
      slug: "untitled-#{Slug.random_suffix()}"
    }

    {:ok, ContentTypes.create!(kind, Map.merge(scaffold, extra), actor: actor, tenant: org)}
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Invalid] -> {:error, error}
  end
end
