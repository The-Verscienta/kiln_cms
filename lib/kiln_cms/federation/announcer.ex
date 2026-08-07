defmodule KilnCMS.Federation.Announcer do
  @moduledoc """
  Turns an editorial event into a federation announcement (#491).

  Called from `KilnCMS.Federation.handle_event/3`, which is called from
  `KilnCMS.Webhooks.dispatch/3` **inside the publish transaction**. So this
  does one thing: enqueue an `AnnounceWorker` job. Every decision that needs a
  database read — is this site federating, does this type syndicate, is the
  record public — happens in the worker, after the transaction has committed
  and the record it would read actually exists.

  ## Verb mapping

  | Editorial event | Activity |
  |---|---|
  | `<type>.published` | `Create` |
  | `<type>.updated` | `Update` |
  | `<type>.unpublished` | `Delete` |

  `in_review` and `returned_to_draft` are workflow states, not publication
  events, and federate nothing — a follower has no business learning that a
  draft moved between editorial columns.
  """

  alias KilnCMS.Federation.AnnounceWorker

  @verbs %{
    "published" => "Create",
    "updated" => "Update",
    "unpublished" => "Delete"
  }

  @doc """
  Enqueue an announcement for `event`, if it is one that federates.

  Returns `:ok` either way — "this event does not federate" is the common case,
  not an error.
  """
  @spec announce(String.t(), map(), Ash.ToTenant.t() | nil) :: :ok
  def announce(event, payload, org) do
    with {:ok, type, verb} <- parse(event),
         id when is_binary(id) <- payload["id"] || payload[:id] do
      %{
        "org_id" => org_id(org),
        "type" => type,
        "verb" => verb,
        "document_id" => id
      }
      |> AnnounceWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  defp parse(event) when is_binary(event) do
    case String.split(event, ".") do
      [type, action] ->
        case Map.fetch(@verbs, action) do
          {:ok, verb} -> {:ok, type, verb}
          :error -> :skip
        end

      _other ->
        :skip
    end
  end

  defp parse(_event), do: :skip

  defp org_id(%{id: id}), do: id
  defp org_id(org) when is_binary(org), do: org
  defp org_id(_other), do: KilnCMS.Accounts.default_org_id()
end
