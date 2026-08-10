defmodule KilnCMS.CMS.Changes.NotifyWebhooks do
  @moduledoc """
  After a content lifecycle action, dispatch a `<type>.<event>` webhook with
  the serialized content. Attach to an action and pass the event name:

      change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "published"}
      change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "unpublished"}

  Defaults to `"published"`.

  Pass `only_when: :published` to dispatch only when the resulting record is in
  the `:published` state. This is used by the generic `update` action so edits
  to drafts (and autosaves) stay silent, while edits to live content emit a
  `<type>.updated` event.

  Pass `only_when: :was_published` to dispatch only when the record was
  `:published` **before** this action ran, regardless of what it transitions
  to. `:published` above checks the *resulting* record, which is the wrong
  side of a transition that always leaves one fixed state on the way out —
  `:archive` (`from: [:draft, :in_review, :published]`, always landing on
  `:archived`) is exactly that case (#914): a plain `only_when: :published`
  would never fire, since the resulting state is never `:published`, but the
  question that actually matters is whether delivery had anything to remove.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.Webhooks

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.get(opts, :event, "published")
    only_when = Keyword.get(opts, :only_when)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if dispatch?(only_when, changeset, record) do
        # Scope the fan-out to the publishing record's own site (epic #336) so a
        # publish only reaches its org's subscribed endpoints.
        Webhooks.dispatch(
          "#{event_prefix(record)}.#{event}",
          ContentSerializer.to_map(record),
          record.org_id
        )
      end

      {:ok, record}
    end)
  end

  defp dispatch?(nil, _changeset, _record), do: true
  defp dispatch?(:published, _changeset, %{state: :published}), do: true
  defp dispatch?(:published, _changeset, _record), do: false
  # `changeset.data` is the record as it was BEFORE this action's changes —
  # the pre-transition state, unlike `record` (the post-action result).
  defp dispatch?(:was_published, changeset, _record),
    do: changeset.data.state == :published

  # Derive the event namespace from the content type's module name
  # (`KilnCMS.CMS.Page` -> `"page"`), so every content type — including ones
  # generated via `mix kiln.gen.content` — dispatches webhooks without changes
  # here. Generic entries (D17) use their dynamic type's *name* instead
  # (`"recipe.published"`, not `"entry.published"`), so subscribers filter
  # dynamic types exactly like compiled ones.
  defp event_prefix(%resource{} = record) do
    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      KilnCMS.Firing.Engine.public_type(record)
    else
      resource |> Module.split() |> List.last() |> Macro.underscore()
    end
  end
end
