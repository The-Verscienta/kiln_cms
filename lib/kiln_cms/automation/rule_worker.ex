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
    # Subject is a header: render it as plain text with CR/LF stripped so a
    # content title can't inject extra headers. Body is HTML: escape markup.
    send_rule_email(
      config,
      render(config["subject"] || "Kiln automation: {{title}}", event, payload, :text),
      render(config["body"] || default_body(), event, payload, :html)
    )
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

  # Embedding-driven editorial intelligence (#377): notify editors of
  # near-duplicate content — a lightweight review gate ("on in_review → email
  # any suspiciously similar documents"). Silent when nothing is found.
  defp run(%{action: :flag_duplicates, config: config, org_id: org_id}, event, payload) do
    intelligence(event, payload, org_id, config, &duplicate_findings/1)
  end

  # Tag suggestions for the document under review (#377), from the existing
  # taxonomy ranked by semantic similarity. Silent when nothing to suggest.
  defp run(%{action: :suggest_tags, config: config, org_id: org_id}, event, payload) do
    intelligence(event, payload, org_id, config, &tag_findings/1)
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

  # The public content type from a `<type>.<verb>` event name.
  defp event_type(event), do: event |> String.split(".", parts: 2) |> List.first()

  # ── editorial intelligence (#377) ─────────────────────────────────────────

  # Load the live document, run the finder, and email the findings (if any).
  # A transient read failure returns the error so Oban retries; a vanished
  # type/document or empty findings is a clean no-op.
  defp intelligence(event, payload, org_id, config, finder) do
    case load_document(event, payload, org_id) do
      {:ok, record} -> deliver_findings(finder.(record), config)
      {:error, error} -> {:error, error}
      :skip -> :ok
    end
  end

  defp load_document(event, payload, org_id) do
    with type when is_binary(type) <- event_type(event),
         id when is_binary(id) <- payload["id"],
         storage when not is_nil(storage) <- ContentTypes.storage_type(type, org_id) do
      ContentTypes.get_record(type, id, authorize?: false, tenant: org_id, load: [:tags])
    else
      _ -> :skip
    end
  end

  defp deliver_findings(:none, _config), do: :ok

  defp deliver_findings({subject, html_body}, config),
    do: send_rule_email(config, escape(subject, :text), html_body)

  # One delivery skeleton for every emailing reaction, so header/policy
  # changes (from-address, missing-`to` handling) can't diverge per action.
  defp send_rule_email(config, subject_text, html) do
    to = config["to"]

    if is_binary(to) and to != "" do
      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(to)
      |> subject(subject_text)
      |> html_body(html)
      |> KilnCMS.Mail.deliver_for_worker()
    else
      Logger.warning("Automation email rule missing a `to` address; skipping.")
      :ok
    end
  end

  defp duplicate_findings(record) do
    case KilnCMS.Search.Related.near_duplicates(record) do
      [] ->
        :none

      dups ->
        items =
          Enum.map_join(dups, "", fn d ->
            "<li>#{escape(d.title || d.slug, :html)} (#{escape(d.type, :html)}/#{escape(d.slug, :html)})</li>"
          end)

        {"Review note: possible duplicates of \"#{record.title}\"",
         "<p>Content similar to <strong>#{escape(record.title, :html)}</strong> already exists:</p>" <>
           "<ul>#{items}</ul>"}
    end
  end

  defp tag_findings(record) do
    case KilnCMS.Search.Related.suggest_tags(record) do
      [] ->
        :none

      suggestions ->
        items = Enum.map_join(suggestions, "", &"<li>#{escape(&1.tag.name, :html)}</li>")

        {"Tag suggestions for \"#{record.title}\"",
         "<p>Suggested tags for <strong>#{escape(record.title, :html)}</strong>:</p>" <>
           "<ul>#{items}</ul>"}
    end
  end

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
