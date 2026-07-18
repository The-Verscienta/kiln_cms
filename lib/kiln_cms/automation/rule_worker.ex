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
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  import Swoosh.Email

  require Logger

  alias KilnCMS.Automation
  alias KilnCMS.CMS.ContentTypes

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"rule_id" => rule_id, "event" => event, "payload" => payload}}) do
    case Automation.get_rule(rule_id, authorize?: false) do
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
      |> subject(render(config["subject"] || "Kiln automation: {{title}}", event, payload))
      |> html_body(render(config["body"] || default_body(), event, payload))
      |> KilnCMS.Mail.deliver_for_worker()
    else
      Logger.warning("Automation send_email rule missing a `to` address; skipping.")
      :ok
    end
  end

  defp run(%{action: :broadcast, config: config}, event, payload) do
    topic = config["topic"] || "automation"
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:automation_event, event, payload})
  end

  defp run(%{action: :invalidate_cache}, event, payload) do
    type = event_type(event)
    slug = payload["slug"]

    if is_binary(type) and is_binary(slug), do: KilnCMS.Cache.bust(type, slug)
    KilnCMS.Cache.bust_sitemap()
    KilnCMS.Cache.bust_llms()
    :ok
  end

  defp run(%{action: :reindex}, event, payload) do
    with type when is_binary(type) <- event_type(event),
         id when is_binary(id) <- payload["id"],
         storage when not is_nil(storage) <- storage_type(type) do
      %{"type" => to_string(storage), "id" => id}
      |> KilnCMS.Firing.FireWorker.new()
      |> Oban.insert()

      :ok
    else
      _ -> :ok
    end
  end

  # The public content type from a `<type>.<verb>` event name.
  defp event_type(event), do: event |> String.split(".", parts: 2) |> List.first()

  # The storage tier for a public type: dynamic types live under the generic
  # `:entry` tier (D17), compiled types under their own atom.
  defp storage_type(type) do
    case ContentTypes.get(type) do
      %{source: :dynamic} -> :entry
      %{type: atom} -> atom
      _ -> nil
    end
  end

  defp default_body do
    "<p>The content <strong>{{title}}</strong> ({{type}}) emitted <em>{{event}}</em>.</p>"
  end

  # Minimal, safe templating: substitute a fixed set of payload fields, each
  # HTML-escaped (author-supplied title/slug must not inject markup into email).
  defp render(template, event, payload) do
    vars = %{
      "title" => payload["title"],
      "slug" => payload["slug"],
      "id" => payload["id"],
      "type" => event_type(event),
      "event" => event
    }

    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn whole, key ->
      case Map.fetch(vars, key) do
        {:ok, value} when not is_nil(value) -> escape(value)
        _ -> whole
      end
    end)
  end

  defp escape(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
