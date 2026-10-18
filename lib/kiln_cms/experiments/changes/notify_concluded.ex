defmodule KilnCMS.Experiments.Changes.NotifyConcluded do
  @moduledoc """
  Emits `experiment.concluded` when an experiment finishes (#499).

  Goes through `KilnCMS.Webhooks.dispatch/3` — the one funnel webhook endpoints,
  automation rules and ActivityPub federation already share. No automation
  rule reacts to it: `concluded` is not a rule trigger
  (`KilnCMS.Automation.Rule.triggers/0`). Were it to become one, it is a
  domain event (`KilnCMS.CMS.WebhookEndpoint.domain_events/0`), so only a rule
  scoped to `content_type: "experiment"` would match it (#1995).

  `after_transaction`, so nothing is announced that did not commit. The payload
  carries `id`, which the automation dispatcher would dedupe on.
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
