defmodule KilnCMS.CMS.Changes.NotifyWebhooks do
  @moduledoc """
  After a content lifecycle action, dispatch a `<type>.<event>` webhook with
  the serialized content. Attach to an action and pass the event name:

      change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "published"}
      change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "unpublished"}

  Defaults to `"published"`.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.Webhooks

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.get(opts, :event, "published")

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Webhooks.dispatch("#{event_prefix(record)}.#{event}", ContentSerializer.to_map(record))
      {:ok, record}
    end)
  end

  # Derive the event namespace from the content type's module name
  # (`KilnCMS.CMS.Page` -> `"page"`), so every content type — including ones
  # generated via `mix kiln.gen.content` — dispatches webhooks without changes
  # here.
  defp event_prefix(%resource{}),
    do: resource |> Module.split() |> List.last() |> Macro.underscore()
end
