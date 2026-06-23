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
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.Webhooks

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.get(opts, :event, "published")
    only_when = Keyword.get(opts, :only_when)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      if dispatch?(only_when, record) do
        Webhooks.dispatch("#{event_prefix(record)}.#{event}", ContentSerializer.to_map(record))
      end

      {:ok, record}
    end)
  end

  defp dispatch?(nil, _record), do: true
  defp dispatch?(:published, %{state: :published}), do: true
  defp dispatch?(:published, _record), do: false

  # Derive the event namespace from the content type's module name
  # (`KilnCMS.CMS.Page` -> `"page"`), so every content type — including ones
  # generated via `mix kiln.gen.content` — dispatches webhooks without changes
  # here.
  defp event_prefix(%resource{}),
    do: resource |> Module.split() |> List.last() |> Macro.underscore()
end
