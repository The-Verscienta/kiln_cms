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
    * `:social_post` — announce the publish on the site's Bluesky / Mastodon
      accounts (#497; `config` `"provider"` required, `"template"` optional).
      **At most once** per {rule, account, document, publish}, and never
      retried on an ambiguous outcome — see `KilnCMS.Social`.
    * `:newsletter` — send the published document to subscribers via
      `KilnCMS.Newsletter` (#376; `config` `"segment_id"`/`"subject"`, both
      optional). Deduped per {rule, content, publish revision}.
    * `:flag_duplicates` / `:suggest_tags` / `:suggest_links` /
      `:suggest_metadata` — the editorial-intelligence reactions (#377); see
      below.

  ## The editorial-intelligence reactions suggest, and never write

  `docs/automation.md` states it as a rule and this is where it is enforced:
  these four compute something about the document under review and **email the
  findings**. None of them touches the record.

  That is the design answer to why #377's automation form was held back.
  Generated metadata lands in `<meta>` tags on the public site, so a successful
  prompt injection through the body buys SEO cloaking on the operator's own
  domain — and human-in-the-loop is the *primary* control against that; the
  output constraints in `KilnCMS.Seo.Draft` are only the second layer. A
  reaction that wrote `seo_description` unattended on a state transition would
  delete the primary control. So automation makes the **computation**
  unattended — the editor no longer has to open the panel and ask — while
  accepting a value stays a click in the editor, where a human sees it first.

  For the same reason these reactions are advisory about their own failures: a
  provider outage, an exhausted budget bucket or an unconfigured generator is
  logged and dropped, not retried. Retrying a nice-to-have suggestion five
  times per document costs real tokens to tell an editor something they can ask
  for directly.
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
    case Automation.get_rule(rule_id,
           authorize?: false,
           tenant: args["org_id"] || KilnCMS.Accounts.default_org_id()
         ) do
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
         {:ok, record} <- ContentTypes.get_record(type, id, authorize?: false, tenant: org_id),
         :ok <- default_locale_only(record, event) do
      KilnCMS.Newsletter.send_as_newsletter(record,
        segment_id: config["segment_id"],
        subject: config["subject"],
        automation: %{rule_id: rule_id, published_at: record.published_at}
      )
      |> settle_newsletter(record, event)
    else
      # A transient read failure (DB blip) must retry, not silently drop the
      # campaign; the nil/skip guards above fall through to a clean :ok.
      {:error, error} -> {:error, error}
      :skipped_locale -> :ok
      _ -> :ok
    end
  end

  # Embedding-driven editorial intelligence (#377): notify editors of
  # near-duplicate content — a lightweight review gate ("on in_review → email
  # any suspiciously similar documents"). Silent when nothing is found.
  defp run(%{action: :flag_duplicates} = rule, event, payload) do
    intelligence(rule, event, payload, &duplicate_findings/2)
  end

  # Tag suggestions for the document under review (#377), from the existing
  # taxonomy ranked by semantic similarity. Silent when nothing to suggest.
  defp run(%{action: :suggest_tags} = rule, event, payload) do
    intelligence(rule, event, payload, &tag_findings/2)
  end

  # #377 box 1, auto internal-linking, in its automation form: the same
  # `KilnCMS.Seo.Links` suggester the editor panel lazy-loads, run on the
  # transition instead of on a panel open, and mailed as copyable paths.
  #
  # Deterministic and local — the semantic leg is pgvector over content this
  # deployment already indexed, and the keyword fallback is Postgres full-text.
  # No model, no egress, works on a default install.
  defp run(%{action: :suggest_links} = rule, event, payload) do
    intelligence(rule, event, payload, &link_findings/2)
  end

  # #377 box 2, metadata generation on a state transition. Runs the same
  # `KilnCMS.Seo.draft/2` the editor's "Suggest with AI" button runs and mails
  # the proposal. **Nothing is written** — see the moduledoc.
  defp run(%{action: :suggest_metadata} = rule, event, payload) do
    intelligence(rule, event, payload, &metadata_findings/2)
  end

  # "On publish → announce it" (#497). Loads the live record (the payload is a
  # serialized snapshot) and hands it to `KilnCMS.Social.Announcer`, which claims
  # a ledger row before it posts and refuses gated, locked and non-default-locale
  # documents.
  #
  # Every outcome that is not a transient read failure returns `:ok`. This job
  # must not retry: Oban retrying a post whose response was lost is exactly how
  # one announcement becomes two, and the ledger already records the ambiguity
  # for a human. `{:error, _}` is reserved for "we never got as far as trying".
  defp run(%{action: :social_post, config: config, org_id: org_id, id: rule_id}, event, payload) do
    with type when is_binary(type) <- event_type(event),
         id when is_binary(id) <- payload["id"],
         provider when not is_nil(provider) <- social_provider(config),
         true <- KilnCMS.Social.configured?(org_id),
         storage when not is_nil(storage) <- ContentTypes.storage_type(type, org_id),
         {:ok, record} <-
           ContentTypes.get_record(type, id,
             authorize?: false,
             tenant: org_id,
             # `KilnCMS.Social.Composer` posts the type's #805 default where the
             # record has no description of its own (#1102); the calculation's
             # `load/3` is what makes `[category]` resolve to the same name the
             # document's own page shows.
             load: KilnCMS.Seo.Patterns.loads()
           ) do
      announce_to(record, provider, org_id, rule_id, config["template"])
    else
      # A transient read failure (a DB blip) is worth retrying — nothing was
      # posted, so a retry cannot duplicate anything.
      {:error, error} -> {:error, error}
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

  defp announce_to(record, provider, org_id, rule_id, template) do
    KilnCMS.Social.accounts_for_provider!(provider, authorize?: false, tenant: org_id)
    |> Enum.each(fn account ->
      case KilnCMS.Social.Announcer.announce(record, account,
             automation_rule_id: rule_id,
             template: template
           ) do
        {:ok, _post} ->
          :ok

        # The claim was already taken — a re-delivered job or a re-fire wave.
        # This is the guarantee working, not a failure.
        {:error, :already_announced} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Social announce failed for #{account.provider} " <>
              "#{record.__struct__}/#{record.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  # The rule names its provider as a string; only the ones with an
  # implementation are accepted, and an unknown value is dropped rather than
  # turned into an atom.
  defp social_provider(%{"provider" => provider}) when is_binary(provider) do
    Enum.find(KilnCMS.Social.Account.providers(), &(to_string(&1) == provider))
  end

  defp social_provider(_config), do: nil

  # Content is modeled per-locale, and every locale variant's publish emits its
  # own event — without this guard one article published in three languages
  # would email the whole list three times. Campaigns follow the default-locale
  # variant; per-locale campaigns can use a content_type-scoped rule + segment.
  defp default_locale_only(record, event) do
    if Map.get(record, :locale, KilnCMS.I18n.default_locale()) == KilnCMS.I18n.default_locale() do
      :ok
    else
      Logger.info("Automation newsletter rule skipped #{event}: non-default locale variant")
      :skipped_locale
    end
  end

  defp settle_newsletter({:ok, _send}, _record, _event), do: :ok
  defp settle_newsletter({:error, :already_sent}, _record, _event), do: :ok

  # Publish fires artifacts on a sibling Oban job — retry briefly until the
  # :web artifact exists. Oban snoozes don't consume attempts, so bound the
  # loop by the publish's age: past the window, firing is broken and retrying
  # can't help.
  defp settle_newsletter({:error, :not_fired}, record, event) do
    if recent_publish?(record) do
      {:snooze, 30}
    else
      Logger.warning(
        "Automation newsletter rule gave up on #{event}: no fired artifact " <>
          "#{inspect(@fire_wait_limit_s)}s after publish"
      )

      :ok
    end
  end

  defp settle_newsletter({:error, reason}, _record, event)
       when reason in [:not_published, :gated] do
    Logger.info("Automation newsletter rule skipped #{event}: #{inspect(reason)}")
    :ok
  end

  defp settle_newsletter({:error, other}, _record, _event), do: {:error, other}

  defp recent_publish?(%{published_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) < @fire_wait_limit_s

  defp recent_publish?(_record), do: false

  # The public content type from a `<type>.<verb>` event name.
  defp event_type(event), do: event |> String.split(".", parts: 2) |> List.first()

  # ── editorial intelligence (#377) ─────────────────────────────────────────

  # Load the live document, run the finder, and email the findings (if any).
  # A transient read failure returns the error so Oban retries; a vanished
  # type/document or empty findings is a clean no-op.
  defp intelligence(%{config: config, org_id: org_id, id: rule_id}, event, payload, finder) do
    case load_document(event, payload, org_id) do
      {:ok, record} ->
        context = %{
          org_id: org_id,
          rule_id: rule_id,
          config: config,
          content_type: event_type(event)
        }

        record
        |> finder.(context)
        |> attribute(context)
        |> deliver_findings(config)

      {:error, error} ->
        {:error, error}

      :skip ->
        :ok
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

  # Name the rule and the org in the skip reason. A rule refused by its
  # unattended share (#943) is not a blip — it is a steady state that can hold
  # for the rest of the window, every window — and an unattributed line leaves
  # an admin with several `suggest_metadata` rules unable to tell which one is
  # being refused, or for which site. That is #944's failure mode wearing a log
  # message.
  defp attribute({:skip, reason}, %{rule_id: rule_id, org_id: org_id}) do
    {:skip, "#{reason} (rule #{rule_id}, org #{org_id})"}
  end

  defp attribute(findings, _context), do: findings

  defp deliver_findings(:none, _config), do: :ok

  # A reason the finder couldn't run at all — an unconfigured generator, an
  # exhausted budget, a provider that fell over. Logged and dropped rather than
  # returned as an error: see the moduledoc on why these reactions don't retry.
  defp deliver_findings({:skip, reason}, _config) do
    Logger.info("Automation intelligence rule produced nothing: #{reason}")
    :ok
  end

  # The delivery half of the same no-retry posture. `Mail.deliver_for_worker/2`
  # *raises* on a transient failure (greylisting, a DNS blip, a refused relay)
  # so Oban retries the job — and a retry re-enters `run/3` from the top, which
  # for `:suggest_metadata` means generating the draft again. A greylisted
  # relay during a bulk move to `in_review` would then bill five generations,
  # and ship five copies of each body off-site, to deliver one email.
  #
  # Only these reactions swallow it. A `:send_email` or `:newsletter` rule is
  # the message; here the message is advisory and the expensive part already
  # happened.
  defp deliver_findings({subject, html_body}, config) do
    send_rule_email(config, escape(subject, :text), html_body)
  rescue
    error in [KilnCMS.Mail.TransientDeliveryError] ->
      Logger.warning(
        "Automation intelligence rule couldn't deliver its findings; dropping rather " <>
          "than retrying a generation that already ran: #{Exception.message(error)}"
      )

      :ok
  end

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

  # ── #377 box 1: auto internal-linking ─────────────────────────────────────

  defp link_findings(record, _context) do
    case KilnCMS.Seo.Links.suggest(record) do
      [] ->
        :none

      suggestions ->
        items =
          Enum.map_join(suggestions, "", fn s ->
            "<li><code>#{escape(s.path, :html)}</code> — #{escape(s.title || s.slug, :html)}" <>
              " <em>(#{s.source})</em></li>"
          end)

        {"Internal links to consider for \"#{record.title}\"",
         "<p>Pages worth linking to from <strong>#{escape(record.title, :html)}</strong>:</p>" <>
           "<ul>#{items}</ul>" <>
           "<p>These are paths to paste into the body — nothing was inserted. " <>
           "Insertion is a client-side editor command by design; see " <>
           "<code>KilnCMS.Seo.Links</code>.</p>"}
    end
  end

  # ── #377 box 2: metadata generation on a state transition ─────────────────

  # Off on a default install (`generator: nil`), so a rule created against a
  # deployment that never configured drafting is inert rather than broken.
  defp metadata_findings(record, context) do
    cond do
      not KilnCMS.Seo.enabled?() ->
        {:skip, "SEO drafting is not configured (config :kiln_cms, KilnCMS.Seo, generator:)"}

      KilnCMS.Seo.egress?() and not egress_allowed?(context.config) ->
        # The panel is one editor deciding to spend one request. A rule is every
        # matching document, forever, with nobody watching — a materially
        # different egress posture than the one the operator agreed to when they
        # configured a third-party provider for the *panel*. Opting in per rule
        # keeps a provider switch from silently turning the whole publish
        # pipeline into an outbound feed.
        {:skip,
         "refusing to send content to #{KilnCMS.Seo.endpoint_host() || KilnCMS.Seo.provider()} " <>
           "unattended: set the rule's config `allow_egress` to true to permit it"}

      true ->
        draft_findings(record, context)
    end
  end

  # Strictly the JSON boolean. Every other key in that textarea is a string, so
  # `"allow_egress": "true"` is the natural mistake — and it fails closed, which
  # from the outside looks like a rule that is enabled, green, and silently
  # emails nothing forever. Warn loudly about the near-miss so it's diagnosable;
  # don't coerce it, because "what counts as true" is the wrong thing to be
  # generous about on an egress gate.
  defp egress_allowed?(%{"allow_egress" => true}), do: true

  defp egress_allowed?(%{"allow_egress" => other}) do
    Logger.warning(
      "Automation rule's `allow_egress` must be the JSON boolean true, got #{inspect(other)}; " <>
        "treating it as not permitted."
    )

    false
  end

  defp egress_allowed?(_config), do: false

  defp draft_findings(record, context) do
    document = KilnCMS.Seo.Document.from_record(record, content_type: context.content_type)

    opts = [
      org_id: context.org_id,
      user_id: budget_identity(context),
      # Nobody is waiting on this one, so it draws on the sub-ceiling rather
      # than the whole org allowance (#943).
      unattended?: true
    ]

    case KilnCMS.Seo.draft(document, opts) do
      {:ok, draft} ->
        {metadata_subject(record), metadata_body(record, draft)}

      # Spelled out rather than inspected: this one is a standing setting
      # (`unattended_share: 0.0`), not an overload, and "rate limited, retry in
      # 3600000ms" would send an operator to wait out a window that will never
      # help.
      {:error, :unattended_disabled} ->
        {:skip,
         "SEO drafting is switched off for unattended callers " <>
           "(config :kiln_cms, KilnCMS.Seo, unattended_share: 0.0)"}

      {:error, {:rate_limited, _ms}} ->
        {:skip,
         "SEO draft budget spent: unattended rules stop once the org reaches " <>
           "#{KilnCMS.Seo.unattended_share()} of per_org_limit, so the rest stays " <>
           "available to editors"}

      {:error, reason} ->
        {:skip, "SEO draft failed: #{inspect(reason)}"}
    end
  end

  # Two ceilings, for two different runaways.
  #
  # Keying the per-user bucket by rule id gives each rule its own ceiling, so
  # one hot rule can't starve the *other rules*. That is all it does — every
  # rule together could still drain the org's whole allowance, and the first an
  # editor would know of it is their own "Suggest with AI" returning a
  # rate-limit error caused by a background rule they can't see and (since
  # `/editor/automation` is admin-only) can't inspect.
  #
  # `unattended?: true` is the other half: unattended callers additionally pass
  # a bucket sized at `KilnCMS.Seo.unattended_share/0` of the per-org count, so
  # the units past that share are reserved for people. The per-org bucket still
  # applies on top, so the operator's total ceiling is the one they configured.
  defp budget_identity(%{rule_id: rule_id}), do: "automation:#{rule_id}"

  defp metadata_subject(record), do: "Suggested SEO metadata for \"#{record.title}\""

  # Every value here is model output over an untrusted body, so all of it is
  # escaped — the same posture `KilnCMS.Seo.Draft.normalize/1` takes on the
  # values themselves.
  defp metadata_body(record, draft) do
    rows =
      [
        {"Title", draft.seo_title},
        {"Description", draft.seo_description},
        {"Keywords", KilnCMS.Seo.Draft.keywords_string(draft)}
      ]
      |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
      |> Enum.map_join("", fn {label, value} ->
        "<li><strong>#{label}:</strong> #{escape(value, :html)}</li>"
      end)

    "<p>Proposed metadata for <strong>#{escape(record.title, :html)}</strong>:</p>" <>
      "<ul>#{rows}</ul>" <>
      "<p><strong>Nothing was written.</strong> Open the SEO panel in the editor to " <>
      "review and accept these — generated metadata is served to search engines, " <>
      "so a human sees it before the public does.</p>"
  end

  defp duplicate_findings(record, _context) do
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

  defp tag_findings(record, _context) do
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
