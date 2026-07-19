defmodule KilnCMS.Automation.RuleWorker do
  @moduledoc """
  Performs one editorial automation rule's reaction, off the publish request
  path (#342). Enqueued by `KilnCMS.Automation.handle_event/2` — one job per
  matching rule per event, so a slow or failing reaction is isolated and retried
  by Oban without affecting the content action or the other rules.

  Reactions:

    * `:send_email` — deliver a Swoosh email (`config` `"to"`/`"subject"`/`"body"`,
      with `{{title}}`/`{{slug}}`/`{{id}}`/`{{type}}`/`{{event}}` interpolation).
    * `:broadcast` — `Phoenix.PubSub` broadcast on `config["topic"]` (default
      `"automation"`) as `{:automation_event, event, payload}`.
    * `:invalidate_cache` — bust the record's content cache (+ sitemap/llms).
    * `:reindex` — re-fire the record (refreshes artifacts + search indexes) via
      `KilnCMS.Firing.FireWorker`.
    * `:newsletter` — send the published document to subscribers via
      `KilnCMS.Newsletter` (#376; `config` `"segment_id"`/`"subject"`, both
      optional). Deduped per {rule, content, publish revision}.
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  import Swoosh.Email

  require Logger

  alias KilnCMS.Automation
  alias KilnCMS.CMS.ContentTypes

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"rule_id" => rule_id, "event" => event, "payload" => payload} = args
      }) do
    # `org_id` scopes the rule read to its own site (epic #336); pre-#336 jobs
    # carry none — a nil tenant reads globally, finding the row by its unique id.
    case Automation.get_rule(rule_id, authorize?: false, tenant: args["org_id"]) do
      {:ok, %{enabled: true} = rule} -> run(rule, event, payload)
      # Rule deleted or disabled since the event fired — nothing to do.
      _ -> :ok
    end
  end

  defp run(%{action: :send_email, config: config}, event, payload) do
    to = config["to"]

    if is_binary(to) and to != "" do
      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(to)
      # Subject is a header: render it as plain text with CR/LF stripped so a
      # content title can't inject extra headers. Body is HTML: escape markup.
      |> subject(render(config["subject"] || "Kiln automation: {{title}}", event, payload, :text))
      |> html_body(render(config["body"] || default_body(), event, payload, :html))
      |> KilnCMS.Mail.deliver_for_worker()
    else
      Logger.warning("Automation send_email rule missing a `to` address; skipping.")
      :ok
    end
  end

  defp run(%{action: :broadcast, config: config}, event, payload) do
    # Namespace the admin-supplied topic so a rule can't broadcast onto an
    # internal topic (e.g. "content_preview:…") and crash unrelated subscribers.
    topic = "automation:" <> (config["topic"] || "automation")
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:automation_event, event, payload})
  end

  defp run(%{action: :invalidate_cache, org_id: org_id}, event, payload) do
    type = event_type(event)
    slug = payload["slug"]

    # Bust the rule's own site (epic #336).
    if is_binary(type) and is_binary(slug), do: KilnCMS.Cache.bust(org_id, type, slug)
    KilnCMS.Cache.bust_sitemap(org_id)
    KilnCMS.Cache.bust_llms(org_id)
    :ok
  end

  # "On publish → send the newsletter" (#376 / #337 phase 2). Loads the live
  # record (the payload is a serialized snapshot) and hands it to the existing
  # newsletter machinery, which refuses unpublished/gated/unfired content. The
  # `automation` key makes {rule, content, publish revision} unique on the send
  # ledger, so a re-fired event or re-delivered job can't double-send; a
  # genuinely new publish (fresh `published_at`) sends again.
  # How long after publish we keep waiting for the fired artifact.
  @fire_wait_limit_s 30 * 60

  defp run(%{action: :newsletter, config: config, org_id: org_id, id: rule_id}, event, payload) do
    with type when is_binary(type) <- event_type(event),
         id when is_binary(id) <- payload["id"],
         # The type may have been deleted/archived since the event fired — the
         # storage lookup is nil-safe where `get_record` would raise (same
         # guard the :reindex clause uses).
         storage when not is_nil(storage) <- ContentTypes.storage_type(type, org_id),
         {:ok, record} <- ContentTypes.get_record(type, id, authorize?: false, tenant: org_id) do
      case KilnCMS.Newsletter.send_as_newsletter(record,
             segment_id: config["segment_id"],
             subject: config["subject"],
             automation: %{rule_id: rule_id, published_at: record.published_at}
           ) do
        {:ok, _send} ->
          :ok

        {:error, :already_sent} ->
          :ok

        {:error, :not_fired} ->
          # Publish fires artifacts on a sibling Oban job — retry briefly until
          # the :web artifact exists. Oban snoozes don't consume attempts, so
          # bound the loop by the publish's age: if the artifact still isn't
          # there well after publish, firing is broken and retrying can't help.
          if recent_publish?(record) do
            {:snooze, 30}
          else
            Logger.warning(
              "Automation newsletter rule gave up on #{event}: no fired artifact " <>
                "#{inspect(@fire_wait_limit_s)}s after publish"
            )

            :ok
          end

        {:error, reason} when reason in [:not_published, :gated] ->
          Logger.info("Automation newsletter rule skipped #{event}: #{inspect(reason)}")
          :ok

        {:error, other} ->
          {:error, other}
      end
    else
      _ -> :ok
    end
  end

  defp run(%{action: :reindex, org_id: org_id}, event, payload) do
    with type when is_binary(type) <- event_type(event),
         id when is_binary(id) <- payload["id"],
         storage when not is_nil(storage) <- ContentTypes.storage_type(type, org_id) do
      # Re-fire under the rule's own site (epic #336).
      %{"org_id" => org_id, "type" => to_string(storage), "id" => id}
      |> KilnCMS.Firing.FireWorker.new()
      |> Oban.insert()

      :ok
    else
      _ -> :ok
    end
  end

  defp recent_publish?(%{published_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) < @fire_wait_limit_s

  defp recent_publish?(_record), do: false

  # The public content type from a `<type>.<verb>` event name.
  defp event_type(event), do: event |> String.split(".", parts: 2) |> List.first()

  defp default_body do
    "<p>The content <strong>{{title}}</strong> ({{type}}) emitted <em>{{event}}</em>.</p>"
  end

  # Minimal, safe templating: substitute a fixed set of payload fields. `:html`
  # escapes markup (email body); `:text` strips CR/LF so a value can't inject a
  # header when the result is used as a Subject.
  defp render(template, event, payload, mode) do
    vars = %{
      "title" => payload["title"],
      "slug" => payload["slug"],
      "id" => payload["id"],
      "type" => event_type(event),
      "event" => event
    }

    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn whole, key ->
      case Map.fetch(vars, key) do
        {:ok, value} when not is_nil(value) -> escape(value, mode)
        _ -> whole
      end
    end)
  end

  defp escape(value, :html) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp escape(value, :text) do
    value |> to_string() |> String.replace(~r/[\r\n]+/, " ")
  end
end
