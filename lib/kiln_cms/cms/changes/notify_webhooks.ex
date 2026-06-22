defmodule KilnCMS.CMS.Changes.NotifyWebhooks do
  @moduledoc """
  After a Page/Post is published, dispatch a `<type>.published` webhook event
  with the serialized content. Attach to publish actions.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.CMS.{Page, Post}
  alias KilnCMS.Webhooks

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Webhooks.dispatch("#{event_prefix(record)}.published", ContentSerializer.to_map(record))
      {:ok, record}
    end)
  end

  defp event_prefix(%Page{}), do: "page"
  defp event_prefix(%Post{}), do: "post"
end
