defmodule KilnCMS.Experiments.Changes.NotifyConcluded do
  @moduledoc """
  Emits `experiment.concluded` when an experiment finishes (#499).

  Goes through `KilnCMS.Webhooks.dispatch/3` — the one funnel webhook endpoints,
  automation rules and ActivityPub federation already share — so an automation
  rule scoped to `content_type: "experiment"` reacts to it with no executor
  change at all. That is the `"task"` precedent (`automation/rule.ex:24-30`):
  `handle_event/3` splits on the first `.` and matches the verb, so a literal
  non-content type works.

  `after_transaction`, so nothing is announced that did not commit. The payload
  carries `id` because the automation dispatcher dedupes on it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, experiment} ->
          KilnCMS.Webhooks.dispatch(
            "experiment.concluded",
            payload(experiment),
            experiment.org_id
          )

          result

        other ->
          other
      end
    end)
  end

  defp payload(experiment) do
    %{
      "id" => experiment.id,
      "name" => experiment.name,
      "content_type" => experiment.content_type,
      "document_id" => experiment.document_id,
      "winner_variant_id" => experiment.winner_variant_id,
      "concluded_at" => experiment.concluded_at
    }
  end
end
