defmodule KilnCMSWeb.GovernanceLive do
  @moduledoc """
  Compliance & governance dashboard (`/editor/governance`) — the visible home for
  the compliance cluster (#352). Per content item it surfaces the editorial
  version timeline (PaperTrail), the linked consents (#356), point-in-time access
  (#338), and a JSON export of the trail. Admin-only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Compliance
  alias KilnCMS.Governance
  alias KilnCMSWeb.EditorLive.Filters

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok, assign(socket, :page_title, gettext("Governance"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:trail, nil)
    |> assign(:content, Governance.content_index(socket.assigns.current_org.id))
    |> assign(:witness, Governance.witness_status(socket.assigns.current_org.id))
    # #858. The claim scan is recomputed here rather than stored, so it is
    # resolved per page load like the witness status beside it — see
    # `KilnCMS.Compliance.Report` for why there is no findings table.
    |> assign(:claims, Compliance.Report.for_org(socket.assigns.current_org.id))
    # Content freshness (docs/content-lifecycles.md). Recomputed per load like
    # the two panels above, and for the same reason: `health` is a calculation,
    # so a stored count would be wrong from the moment a deadline passed.
    |> assign(
      :health,
      KilnCMS.CMS.HealthSummary.for_org(
        socket.assigns.current_org.id,
        socket.assigns.current_user
      )
    )
  end

  defp apply_action(socket, :show, %{"type" => type, "id" => id}) do
    case Governance.trail(type, id, socket.assigns.current_org.id) do
      nil ->
        socket
        |> put_flash(:error, gettext("That content couldn't be found."))
        |> push_navigate(to: ~p"/editor/governance")

      trail ->
        socket
        |> assign(:trail, trail)
        |> assign(:consent_form, blank_consent_form())
    end
  end

  # Record a consent from the dashboard (#352 — consent management UI).
  @impl true
  def handle_event("record_consent", %{"consent" => params}, socket) when is_map(params) do
    item = socket.assigns.trail.item

    attrs =
      %{
        content_type: item.type,
        content_id: item.id,
        kind: params["kind"],
        reference: presence(params["reference"]),
        grantor: presence(params["grantor"]),
        note: presence(params["note"])
      }

    # The consent lands in the content's own site (epic #336) — without the
    # tenant it would default to the default org, invisible to the trail read
    # and to the RequiredConsent publish gate.
    case KilnCMS.CMS.record_consent(attrs,
           actor: socket.assigns.current_user,
           tenant: item.org_id
         ) do
      {:ok, _consent} ->
        {:noreply,
         socket
         |> assign(:trail, Governance.trail(item.type, item.id, item.org_id))
         |> assign(:consent_form, blank_consent_form())
         |> put_flash(:info, gettext("Consent recorded."))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't record that consent."))}
    end
  end

  # Replay a lost retraction from the trail (#1926). Here rather than only on
  # /editor/webhooks, whose list is the 25 newest deliveries: a retraction is
  # given up on about a day after it was sent, by when it has usually scrolled
  # off that list. Read as the signed-in admin under the document's site, so
  # the ledger's own admin-only policy decides.
  def handle_event("redeliver_retraction", %{"id" => id}, socket) when is_binary(id) do
    item = socket.assigns.trail.item

    result =
      with {:ok, delivery} <-
             KilnCMS.CMS.get_webhook_delivery(id,
               actor: socket.assigns.current_user,
               tenant: item.org_id
             ),
           true <- delivery.document_id == item.id,
           %KilnCMS.CMS.WebhookDelivery{} <- KilnCMS.Webhooks.redeliver(delivery) do
        :ok
      end

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:trail, Governance.trail(item.type, item.id, item.org_id))
         |> put_flash(:info, gettext("Redelivery queued."))}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't redeliver that webhook."))}
    end
  end

  defp blank_consent_form,
    do: to_form(%{"kind" => nil, "reference" => "", "grantor" => "", "note" => ""}, as: "consent")

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  # Point-in-time delivery URL (#338) for one publish instant.
  defp point_in_time_url(item, %DateTime{} = at), do: Governance.as_of_url(item, at)

  defp when_str(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  # A give-up time the ledger cannot tell (#1928, `WebhookDelivery.given_up_at/1`).
  defp when_str(nil), do: "—"

  # To the second, with the gap from the transition: the propagation columns
  # are about how long readers kept seeing the old version (#1928).
  defp stamp(nil, _from), do: "—"

  # UTC, like the When column. The date is added once the moment falls on
  # another day than the transition: a retraction is retried for about a day.
  defp stamp(%DateTime{} = at, %DateTime{} = from) do
    format =
      if DateTime.to_date(at) == DateTime.to_date(from), do: "%H:%M:%S", else: "%Y-%m-%d %H:%M:%S"

    "#{Calendar.strftime(at, format)} (+#{elapsed(DateTime.diff(at, from, :millisecond))})"
  end

  defp elapsed(ms) when ms < 1_000, do: gettext("%{count} ms", count: max(ms, 0))

  defp elapsed(ms) when ms < 60_000,
    do: gettext("%{count} s", count: Float.round(ms / 1_000, 1))

  defp elapsed(ms) when ms < 3_600_000,
    do: gettext("%{min} min %{sec} s", min: div(ms, 60_000), sec: rem(div(ms, 1_000), 60))

  defp elapsed(ms),
    do: gettext("%{hours} h %{min} min", hours: div(ms, 3_600_000), min: rem(div(ms, 60_000), 60))

  defp missing_label(:not_measured),
    do: gettext("A restore puts the document back without a propagation record")

  defp missing_label(:not_live),
    do: gettext("No propagation record — nothing was live to take down")

  defp missing_label(:pruned),
    do:
      gettext("Propagation record pruned (kept %{days} days)",
        days: KilnCMS.CMS.Propagation.retention_days()
      )

  defp missing_label(:unrecorded),
    do:
      gettext(
        "No propagation record — made before propagation was recorded (1.4), or its record could not be opened"
      )

  defp cdn_label(:not_configured), do: gettext("not configured")
  defp cdn_label(:pending), do: gettext("enqueued, not yet answered")
  defp cdn_label(:acknowledged), do: gettext("acknowledged")
  defp cdn_label(:failed), do: gettext("failed")

  defp row_chain_label(:verified), do: gettext("verified")
  defp row_chain_label(:unsigned), do: gettext("intact (unsigned)")
  defp row_chain_label(:unverifiable), do: gettext("intact (retired key)")
  defp row_chain_label(:unattested), do: gettext("anchored, not attested")
  defp row_chain_label(:unanchored), do: gettext("not yet anchored")
  defp row_chain_label(:tampered), do: gettext("tampered")

  defp row_chain_tone(verdict) when verdict in [:verified, :unsigned],
    do: "bg-success/15 text-success-ink"

  defp row_chain_tone(verdict) when verdict in [:unverifiable, :unattested],
    do: "bg-warning/15 text-warning-ink"

  defp row_chain_tone(:tampered), do: "bg-error/15 text-error-ink"
  defp row_chain_tone(_unanchored), do: "bg-base-200 text-base-content/60"

  # Compact display of a version value: strings verbatim, everything else
  # inspected and capped (block trees can be huge).
  defp diff_value(nil), do: gettext("(unset)")
  defp diff_value(value) when is_binary(value), do: String.slice(value, 0, 160)

  defp diff_value(value),
    do: value |> inspect(limit: 8, printable_limit: 160) |> String.slice(0, 160)

  attr :chain, :any, required: true
  # `%{attested, next, head}` when the attested prefix stops short of the head
  # (#811), else nil. Resolved in `Governance.trail/3`, not here — see there.
  attr :gap_range, :map, default: nil
  # Whether this chain's anchors could have hit the pre-#598 false-tamper bug
  # (#1058). Resolved in `Governance.trail/3` — see there.
  attr :predates_fold_order?, :boolean, default: false

  # Tamper-evidence status from the signed history anchors (#356).
  defp chain_badge(assigns) do
    ~H"""
    <p class="mt-2 text-sm" data-role="chain-status">
      <span
        :if={@chain == :verified}
        class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success"
      >
        <.icon name="hero-shield-check" class="size-3.5" />
        {gettext("Anchored history verified — chain intact, signature valid")}
      </span>
      <%!-- #811: a chain can have anchors that VERIFY and a newer one that does
            not. The verdict still reads `unsigned`, but calling that "intact"
            claims more than is known — versions past the attested prefix are
            anchored by a row nothing attests, and this is exactly the shape an
            INSERT+DELETE laundering produces. It is also what an honest key
            loss produces, which is why it is stated rather than called
            tampering. --%>
      <span
        :if={@gap_range}
        class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext(
          "Attested only to version %{attested} — versions %{next}-%{head} are anchored but not attested",
          attested: @gap_range.attested,
          next: @gap_range.next,
          head: @gap_range.head
        )}
      </span>
      <span
        :if={@chain == :unsigned and is_nil(@gap_range)}
        class="rounded bg-success/10 px-1.5 py-0.5 text-xs font-medium text-success/80"
      >
        {gettext("History intact (anchor unsigned — no signing key configured)")}
      </span>
      <span
        :if={@chain == :unverifiable and is_nil(@gap_range)}
        class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning"
      >
        {gettext(
          "History intact; signed by a key we no longer hold — add its public half to KILN_PROVENANCE_RETIRED_KEY_FILES to re-check"
        )}
      </span>
      <span
        :if={@chain == :unanchored}
        class="rounded bg-base-200 px-1.5 py-0.5 text-xs font-medium text-base-content/60"
      >
        {gettext("Not yet anchored — anchors are minted at publish")}
      </span>
      <span
        :if={match?({:tampered, _}, @chain)}
        class="rounded bg-error/15 px-1.5 py-0.5 text-xs font-medium text-error"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("HISTORY TAMPERED: %{reason}", reason: elem(@chain, 1))}
      </span>
      <%!-- #1058: a SIBLING note, never a softer color or the verdict's own
            text — the verdict above stays red and stays "TAMPERED" regardless.
            Shown only next to a red verdict: on any other chain state this
            fact is not what a reader needs, and repeating it on every row
            would train them to stop reading it here too. --%>
      <span
        :if={match?({:tampered, _}, @chain) and @predates_fold_order?}
        class="mt-1 block rounded bg-warning/10 px-1.5 py-0.5 text-xs text-warning-ink"
        data-role="chain-legacy-note"
      >
        <.icon name="hero-information-circle" class="size-3.5" />
        {gettext(
          "This document's chain was anchored before the fold order was assigned, so this verdict may be the ordering bug rather than tampering — see #598."
        )}
      </span>
    </p>
    """
  end

  attr :witnessed, :map, required: true

  # Which checkpoint currently witnesses THIS document, and at what anchor
  # position (#731). The chain badge above says the document's own history holds
  # together; this says whether anything outside the database vouches for it.
  #
  # `:none` renders nothing at all. A document younger than the last checkpoint
  # is unwitnessed for a perfectly ordinary reason, and so is every document on
  # a deployment that has not configured a sink — a badge on each of them would
  # be noise that teaches an operator to stop reading badges.
  defp witnessed_badge(assigns) do
    ~H"""
    <p :if={@witnessed.state != :none} class="mt-1 text-sm" data-role="witness-position">
      <span
        :if={@witnessed.state == :witnessed}
        class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success-ink"
      >
        {gettext("Witnessed by checkpoint #%{sequence} at anchor position %{position}",
          sequence: @witnessed.sequence,
          position: @witnessed.anchor_position
        )}
        <span :if={witness_attestation_label(@witnessed.attestation)} class="text-base-content/60">
          · {witness_attestation_label(@witnessed.attestation)}
        </span>
      </span>
      <span
        :if={@witnessed.state == :unreadable}
        class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning-ink"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("This document's checkpoint entry could not be read — it cannot be verified")}
      </span>
      <span
        :if={@witnessed.state == :tampered}
        class="rounded bg-error/15 px-1.5 py-0.5 text-xs font-medium text-error-ink"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("CHECKPOINT TAMPERED: %{reason}", reason: @witnessed.reason)}
      </span>
    </p>
    """
  end

  defp witness_attestation_label(:unsigned), do: gettext("checkpoint unsigned")
  defp witness_attestation_label(:unverifiable), do: gettext("signed by a key we no longer hold")
  # `:ok` and anything unrecognised add nothing — and returning nil is what
  # stops the template rendering a dangling separator with no label after it.
  defp witness_attestation_label(_other), do: nil

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:governance}
    >
      <.index
        :if={is_nil(@trail)}
        content={@content}
        witness={@witness}
        claims={@claims}
        health={@health}
      />
      <.detail :if={@trail} trail={@trail} consent_form={@consent_form} />
    </Layouts.console>
    """
  end

  attr :health, :map, required: true

  # Whether the library is rotting (docs/content-lifecycles.md).
  #
  # #500's calendar answers "what is due this month" and the sweep answers it
  # for a scheduler. Neither answers the question a compliance officer has,
  # which is the aggregate one: how much of what we publish has gone past the
  # date we said we would re-read it by.
  #
  # "No cadences set" is rendered rather than skipped, for the same reason
  # `claims_panel/1` renders "off": a panel showing `0 overdue` on a site that
  # has never set a review cadence states something false in a reassuring voice,
  # and "we checked, nothing is late" is the opposite fact from "we have never
  # asked".
  defp health_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-3" data-role="content-health">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-medium">{gettext("Content health")}</h2>
        <.link
          :if={@health.in_use? and @health.worst != []}
          href={~p"/editor/governance/health.csv"}
          class="text-xs link"
        >
          {gettext("Export CSV")}
        </.link>
      </div>

      <p :if={not @health.in_use?} class="text-sm text-base-content/70">
        {gettext(
          "No published content on this site carries a review cadence or an unpublish date, so there is nothing to age. Set one on a record's Settings tab to start tracking freshness."
        )}
      </p>

      <div :if={@health.in_use?} class="flex flex-wrap gap-2">
        <span
          :for={health <- KilnCMS.CMS.HealthSummary.unhealthy()}
          class={[
            "inline-flex items-baseline gap-1.5 rounded-lg px-2.5 py-1 text-sm",
            @health.counts[health] == 0 && "bg-base-200 text-base-content/50",
            @health.counts[health] > 0 && count_tone(health)
          ]}
        >
          <span class="font-semibold tabular-nums">{@health.counts[health]}</span>
          {health_label(health)}
        </span>
      </div>

      <p
        :if={@health.in_use? and @health.worst == []}
        class="text-sm text-base-content/60"
      >
        {gettext("Everything with a cadence is inside it.")}
      </p>

      <p :if={@health.truncated?} class="text-sm text-warning">
        {gettext("Counts are capped per content type — there may be more than shown.")}
      </p>

      <ul :if={@health.worst != []} class="divide-y divide-base-content/10">
        <li :for={row <- @health.worst} class="flex flex-wrap items-baseline gap-2 py-2">
          <.link
            navigate={~p"/editor/content/#{row.type}/#{row.id}"}
            class="text-sm font-medium hover:underline"
          >
            {row.title}
          </.link>
          <span class="text-xs text-base-content/50">{row.label}</span>
          <.health_badge health={row.health} due_at={row.due_at} />
          <span :if={row.due_at} class="text-xs text-base-content/60">
            {gettext("due %{date}", date: Calendar.strftime(row.due_at, "%Y-%m-%d"))}
          </span>
        </li>
      </ul>

      <%!-- The panel answers "what is late"; these are the full lists to work
           through, in the content list where they can be narrowed by type and
           saved as views. "Never reviewed" is the question the counts above
           cannot answer: a record without a cadence is always fresh. --%>
      <nav
        class="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-t border-base-content/10 pt-3 text-sm"
        data-role="review-queues"
        aria-label={gettext("Review work queues")}
      >
        <span class="text-base-content/60">{gettext("Work queues:")}</span>
        <.link :if={@health.in_use?} navigate={~p"/editor?health=due"} class="link">
          {gettext("Review due")}
        </.link>
        <.link navigate={~p"/editor?reviewed=never"} class="link">
          {gettext("Never reviewed")}
        </.link>
        <.link
          :for={kind <- Filters.consent_kinds()}
          navigate={~p"/editor?#{%{consent_missing: kind}}"}
          class="link"
        >
          {gettext("No %{kind} consent", kind: Filters.consent_kind_label(kind))}
        </.link>
      </nav>
    </section>
    """
  end

  defp count_tone(:expired), do: "bg-error/12 text-error-ink"
  defp count_tone(:overdue), do: "bg-error/12 text-error-ink"
  defp count_tone(:due), do: "bg-warning/20 text-warning-ink"
  defp count_tone(_due_soon), do: "bg-info/12 text-info-ink"

  attr :claims, :map, required: true

  # What this site is currently claiming (#858).
  #
  # #377 put claim checking in the editor's panel and the publish gate's
  # refusal, both of which are about the document in front of you. Neither can
  # answer the question a compliance officer actually has — what is published in
  # our name right now — and `docs/p3-plan.md` said this dashboard was where
  # that answer would live. It did not, until now.
  #
  # "Off" is rendered rather than skipped, for `witness_panel/1`'s reason one
  # section up: a page that shows nothing when the scan never ran looks exactly
  # like a page that scanned and found nothing, and those are opposite facts.
  defp claims_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-3" data-role="claim-findings">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-medium">{gettext("Live claims")}</h2>
        <span :if={@claims.enabled?} class="text-xs text-base-content/60">
          {ngettext(
            "%{count} published document scanned",
            "%{count} published documents scanned",
            @claims.scanned,
            count: @claims.scanned
          )}
        </span>
      </div>

      <p :if={not @claims.enabled?} class="text-sm text-base-content/70">
        {gettext(
          "Claim checking is off for this site, so nothing has been scanned. Turn it on at Claim checking to see what is published in your name."
        )}
        <.link navigate={~p"/editor/compliance"} class="link">{gettext("Claim checking")}</.link>
      </p>

      <p
        :if={@claims.enabled? and @claims.findings == []}
        class="text-sm text-base-content/60"
      >
        {gettext("No flagged claims in anything currently published.")}
      </p>

      <p :if={@claims.truncated?} class="text-sm text-warning">
        {gettext(
          "Only the %{count} most recently updated published documents were scanned; there may be more.",
          count: @claims.scanned
        )}
      </p>

      <ul :if={@claims.findings != []} class="divide-y divide-base-content/10">
        <li :for={finding <- @claims.findings} class="flex flex-wrap items-baseline gap-2 py-2">
          <.link
            navigate={~p"/editor/governance/#{finding.type}/#{finding.id}"}
            class="text-sm font-medium hover:underline"
          >
            {finding.title}
          </.link>
          <span class="text-xs text-base-content/50">{finding.type}</span>
          <.badge :if={finding.errors?} variant="error">
            {gettext("would refuse a publish")}
          </.badge>
          <span class="w-full font-mono text-xs text-base-content/70">
            {finding.matches |> Enum.flat_map(fn {_code, phrases} -> phrases end) |> Enum.join(", ")}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :witness, :map, required: true

  # Whether this deployment's history is actually being witnessed (#731).
  #
  # It leads the dashboard rather than sitting at the bottom, because the whole
  # point is that an operator should not be able to read a healthy-looking page
  # and infer a working witness. A silently unwitnessed deployment used to be
  # indistinguishable from a healthy one here — `witness_error` was written on
  # every failed publication and shown nowhere.
  #
  # "Off" and "broken" are rendered differently on purpose. Checkpointing
  # disabled, or no sink configured, are deliberate postures and get a neutral
  # note; a configured sink that is refusing publications is the alarming case
  # and is the only one that gets a warning tone.
  defp witness_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-3" data-role="witness-status">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-medium">{gettext("History witness")}</h2>
        <span class="font-mono text-xs text-base-content/60">{@witness.adapter}</span>
      </div>

      <p :if={not @witness.checkpointing?} class="text-sm text-base-content/70">
        {gettext(
          "Checkpointing is switched off, so no checkpoints are being minted and nothing is published to a witness."
        )}
      </p>

      <p
        :if={@witness.checkpointing? and not @witness.witnessing?}
        class="text-sm text-base-content/70"
      >
        {gettext(
          "No external witness is configured. Checkpoints are minted and stored in this database only, so they attest history against edits — but not against someone who can write to the database itself."
        )}
      </p>

      <%!-- How to turn it on (#1845): "none" is the shipped default, with no
            safe automatic choice, so the panel names the setting rather than
            leaving the reader to find it. --%>
      <p
        :if={@witness.checkpointing? and not @witness.witnessing?}
        id="witness-setup"
        class="text-sm text-base-content/70"
      >
        {gettext("To publish checkpoints outside the database, set this on the server:")}
        <code class="font-mono text-xs">KILN_GOVERNANCE_WITNESS=file|s3|http</code>
        <a
          href={docs_url("governance-dashboard.md")}
          target="_blank"
          rel="noopener"
          class="link inline-flex items-center gap-1 font-medium text-primary-ink"
        >
          {gettext("Learn more")}
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          <span class="sr-only">{gettext("(opens in a new tab)")}</span>
        </a>
      </p>

      <p
        :if={@witness.checkpointing? and is_nil(@witness.latest)}
        class="text-sm text-base-content/60"
      >
        {gettext("No checkpoint has been minted yet.")}
      </p>

      <dl :if={@witness.latest} class="grid gap-3 text-sm sm:grid-cols-3">
        <div>
          <dt class="text-xs text-base-content/60">{gettext("Last checkpoint")}</dt>
          <dd class="tabular-nums">#{@witness.latest.sequence}</dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/60">{gettext("Covering")}</dt>
          <dd>
            {ngettext("%{count} document", "%{count} documents", @witness.latest.document_count,
              count: @witness.latest.document_count
            )}
            <span class="text-base-content/60">· {when_str(@witness.latest.covered_at)}</span>
          </dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/60">{gettext("Published to the witness")}</dt>
          <dd>
            <span :if={@witness.latest.witnessed_at}>{when_str(@witness.latest.witnessed_at)}</span>
            <span :if={is_nil(@witness.latest.witnessed_at)} class="text-base-content/60">
              {gettext("not yet")}
            </span>
          </dd>
        </div>
      </dl>

      <%!-- Shown whichever way the switch resolved, and NOT gated on
            `witnessing?`. An unrecognised `KILN_GOVERNANCE_WITNESS` falls back
            to `None` with a warning that only reaches stderr, so gating here
            would present a real outage as a deliberate posture — a dashboard
            that reads exactly as healthy, which is the hole #731 closes. Only
            the tone depends on whether anything actually refused. --%>
      <div
        :if={@witness.unwitnessed_count > 0}
        class={[
          "rounded-lg p-3 text-sm",
          if(@witness.error,
            do: "border border-warning/40 bg-warning/10 text-warning-ink",
            else: "bg-base-200 text-base-content/70"
          )
        ]}
      >
        <%!-- With no witness and nothing refused, the backlog is waiting, not
              failing (#1845) — but still counted, and the typo case is named,
              since an unrecognised value lands here too. --%>
        <p :if={awaiting_witness?(@witness)} class="font-medium">
          {ngettext(
            "%{count} checkpoint will be published once a witness is configured.",
            "%{count} checkpoints will be published once a witness is configured.",
            @witness.unwitnessed_count,
            count: backlog_count(@witness)
          )}
        </p>
        <p :if={awaiting_witness?(@witness)} class="mt-1">
          {gettext(
            "If KILN_GOVERNANCE_WITNESS is already set, check its value: an unrecognised value falls back to none."
          )}
        </p>
        <p :if={not awaiting_witness?(@witness)} class="font-medium">
          {ngettext(
            "%{count} checkpoint has not been published to the witness.",
            "%{count} checkpoints have not been published to the witness.",
            @witness.unwitnessed_count,
            count: backlog_count(@witness)
          )}
        </p>
        <p :if={@witness.oldest_unwitnessed} class="mt-1">
          {gettext("The oldest covers history up to %{at}.",
            at: when_str(@witness.oldest_unwitnessed.covered_at)
          )}
        </p>
        <%!-- Attributed to its own checkpoint. The oldest outstanding one often
              has no error at all — a backlog from before a sink was configured
              — and printing last night's failure under February's date says
              something untrue. --%>
        <p :if={@witness.error} class="mt-1 font-mono text-xs break-words">
          {gettext("checkpoint #%{sequence}: %{message}",
            sequence: @witness.error.sequence,
            message: @witness.error.message
          )}
        </p>
      </div>

      <p
        :if={@witness.witnessing? and @witness.unwitnessed_count == 0 and @witness.latest}
        class="text-sm text-success-ink"
      >
        <.icon name="hero-shield-check" class="size-4" />
        {gettext("Every checkpoint has been published to the witness.")}
      </p>
    </section>
    """
  end

  # No sink configured and no publication refused: the backlog is queued for a
  # witness that does not exist yet, which is the shipped default (#1845).
  defp awaiting_witness?(witness), do: not witness.witnessing? and is_nil(witness.error)

  # "50+" past the probe bound, rather than loading a year of rows to be exact
  # about a number nobody acts on.
  defp backlog_count(%{more_unwitnessed?: true, unwitnessed_count: n}), do: "#{n}+"
  defp backlog_count(%{unwitnessed_count: n}), do: n

  attr :content, :list, required: true
  attr :witness, :map, required: true
  attr :claims, :map, required: true
  attr :health, :map, required: true

  defp index(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">{gettext("Governance")}</h1>
        <p class="text-sm text-base-content/70">
          {gettext("Audit trail, consent records, and point-in-time history for your content.")}
        </p>
      </div>

      <.witness_panel witness={@witness} />
      <.claims_panel claims={@claims} />
      <.health_panel health={@health} />

      <.empty_state
        :if={@content == []}
        id="governance-content-empty"
        icon="hero-document-text"
        title={gettext("No content yet.")}
      >
        {gettext("Each page and post gets an audit trail here once it exists.")}
        <:action>
          <.link navigate={~p"/editor"} class="btn btn-sm btn-default">
            {gettext("Go to content")}
          </.link>
        </:action>
      </.empty_state>

      <ul :if={@content != []} class="card divide-y divide-base-content/10 overflow-hidden">
        <li :for={item <- @content} class="flex items-center justify-between p-3">
          <div class="min-w-0">
            <.link
              navigate={~p"/editor/governance/#{item.type}/#{item.id}"}
              class="text-sm font-medium hover:underline"
            >
              {item.title}
            </.link>
            <span class="ml-2 text-xs text-base-content/50">{item.type} · {item.state}</span>
          </div>
          <.link
            navigate={~p"/editor/governance/#{item.type}/#{item.id}"}
            aria-label={gettext("Trail for %{title}", title: item.title)}
            class="btn btn-sm btn-default"
          >
            {gettext("Trail")}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :lost, :list, required: true

  # Retraction webhooks that never reached a consumer (#1926). Only rendered
  # when there is one: an empty "nothing lost" card on every trail would be
  # chrome, and this panel's job is to be impossible to miss when it matters.
  defp lost_retractions_panel(assigns) do
    ~H"""
    <section
      :if={@lost != []}
      id="lost-retractions"
      class="card card-pad space-y-3 border-error/40"
      data-role="lost-retractions"
    >
      <div>
        <h2 class="flex items-center gap-2 text-lg font-medium text-error-ink">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          {gettext("Retractions not delivered")} ({length(@lost)})
        </h2>
        <p class="text-sm text-base-content/70">
          {gettext(
            "These webhook consumers were never told this content was withdrawn, and may still be serving it. Fix the receiver, then redeliver."
          )}
        </p>
      </div>
      <ul class="divide-y divide-base-content/10">
        <li :for={lost <- @lost} id={"lost-retraction-" <> lost.id} class="space-y-0.5 py-2 text-sm">
          <div class="flex flex-wrap items-center gap-2">
            <code class="text-xs">{lost.event}</code>
            <span class="truncate font-medium">{lost.endpoint_url || gettext("deleted endpoint")}</span>
            <span
              :if={lost.recovered_at}
              class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success-ink"
            >
              {gettext("delivered later, %{at}", at: when_str(lost.recovered_at))}
            </span>
            <button
              :if={is_nil(lost.recovered_at) and lost.endpoint_id}
              type="button"
              phx-click="redeliver_retraction"
              phx-value-id={lost.id}
              class="btn btn-sm btn-default ml-auto"
            >
              {gettext("Redeliver")}
            </button>
          </div>
          <p class="text-xs text-base-content/60">
            {gettext("Gave up %{at} after %{count} attempt(s)",
              at: when_str(lost.failed_at),
              count: lost.attempts
            )}<span :if={lost.last_error}> · {lost.last_error}</span>
          </p>
        </li>
      </ul>
      <.link navigate={~p"/editor/webhooks"} class="btn btn-sm btn-default">
        {gettext("Open webhooks")}
      </.link>
    </section>
    """
  end

  attr :transitions, :list, required: true

  # "What readers saw" (#1928): one row per publish or withdrawal, with when
  # each surface actually changed. The version timeline below says what was
  # published; this says when readers stopped seeing the old version.
  defp transitions_panel(assigns) do
    ~H"""
    <section id="transitions" class="space-y-3">
      <div>
        <h2 class="text-lg font-medium">{gettext("What readers saw")}</h2>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Each publish and withdrawal, who approved it, and when the CDN and every webhook endpoint caught up. Times are UTC."
          )}
        </p>
      </div>
      <p :if={@transitions == []} class="text-sm text-base-content/60">
        {gettext("Never published or withdrawn.")}
      </p>
      <div :if={@transitions != []} class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("When")}</th>
              <th>{gettext("Transition")}</th>
              <th>{gettext("Approver")}</th>
              <th>{gettext("CDN purge")}</th>
              <th>{gettext("Webhook endpoints")}</th>
              <th>{gettext("Point in time")}</th>
              <th>{gettext("Chain")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @transitions} id={"transition-#{t.position}"} class="align-top">
              <td class="whitespace-nowrap text-base-content/70">{when_str(t.at)}</td>
              <td>
                <span class={[
                  "rounded px-1.5 py-0.5 text-xs font-medium",
                  t.kind == :publish && "bg-primary/15 text-primary-ink",
                  t.kind == :withdraw && "bg-base-200 text-base-content/70"
                ]}>
                  {t.action}
                </span>
                <span :if={t.scheduled?} class="mt-1 block text-xs text-base-content/60">
                  {gettext("run by the scheduler")}
                </span>
                <span
                  :if={t.action == :restore}
                  class="mt-1 block text-xs text-base-content/60"
                >
                  {gettext("back from the trash, live again")}
                </span>
              </td>
              <td class="whitespace-nowrap text-xs text-base-content/70" data-role="approver">
                {t.approver || "—"}
              </td>
              <%= if t.propagation do %>
                <td class="whitespace-nowrap text-xs" data-role="cdn">
                  <span class={[
                    t.propagation.cdn.status == :failed && "font-medium text-error-ink",
                    t.propagation.cdn.status == :pending && "text-warning-ink"
                  ]}>
                    {cdn_label(t.propagation.cdn.status)}
                  </span>
                  <span
                    :if={t.propagation.cdn.enqueued_at}
                    class="block text-base-content/60"
                  >
                    {gettext("enqueued")} {stamp(t.propagation.cdn.enqueued_at, t.at)}
                  </span>
                  <span
                    :if={t.propagation.cdn.settled_at}
                    class="block text-base-content/60"
                  >
                    {if t.propagation.cdn.status == :failed,
                      do: gettext("gave up"),
                      else: gettext("answered")} {stamp(t.propagation.cdn.settled_at, t.at)}
                  </span>
                </td>
                <td class="text-xs" data-role="endpoints">
                  <span
                    :if={t.propagation.endpoints_expected == 0}
                    class="text-base-content/60"
                  >
                    {gettext("No endpoints subscribed")}
                  </span>
                  <%!-- The ledger is pruned before the record is (#1928): say
                        so, and what the record still knows of them all. --%>
                  <p
                    :if={t.propagation.endpoints_pruned > 0}
                    class="mb-1 text-base-content/60"
                    data-role="endpoints-pruned"
                  >
                    {ngettext(
                      "Sent to %{count} endpoint whose delivery detail was pruned (kept %{days} days).",
                      "Sent to %{count} endpoints whose delivery detail was pruned (kept %{days} days).",
                      t.propagation.endpoints_pruned,
                      days: KilnCMS.CMS.WebhookDelivery.retention_days()
                    )}
                    <span :if={t.propagation.all_delivered_at} class="block">
                      {gettext("All endpoints delivered by")} {stamp(
                        t.propagation.all_delivered_at,
                        t.at
                      )}
                    </span>
                    <span
                      :if={(t.propagation.endpoints_failed || 0) > 0}
                      class="block text-error-ink"
                    >
                      {ngettext(
                        "%{count} endpoint given up on",
                        "%{count} endpoints given up on",
                        t.propagation.endpoints_failed
                      )}
                    </span>
                  </p>
                  <ul :if={t.propagation.endpoints != []} class="space-y-1">
                    <li :for={e <- t.propagation.endpoints} class="min-w-0">
                      <span class="block max-w-xs truncate font-medium">{e.url}</span>
                      <span :if={e.status == :succeeded} class="text-success-ink">
                        {gettext("delivered")} {stamp(e.delivered_at, t.at)}
                      </span>
                      <span :if={e.status == :failed} class="text-error-ink">
                        {gettext("given up")} {stamp(e.failed_at, t.at)}
                        <span :if={e.error} class="block text-base-content/60">{e.error}</span>
                      </span>
                      <span
                        :if={e.status == :failed and e.recovered_at}
                        class="block text-success-ink"
                        data-role="recovered"
                      >
                        {gettext("told later")} {stamp(e.recovered_at, t.at)}
                      </span>
                      <span :if={e.status == :pending} class="text-warning-ink">
                        {gettext("still retrying")}
                      </span>
                    </li>
                  </ul>
                </td>
              <% else %>
                <td colspan="2" class="text-xs text-base-content/60" data-role="no-propagation">
                  {missing_label(t.propagation_missing)}
                </td>
              <% end %>
              <td>
                <a
                  :if={t.as_of_url}
                  href={t.as_of_url}
                  class="text-xs text-primary-ink hover:underline"
                  target="_blank"
                  rel="noopener"
                >
                  {gettext("View as of then")}
                </a>
                <span :if={is_nil(t.as_of_url)} class="text-xs text-base-content/60">—</span>
              </td>
              <td>
                <span
                  class={["rounded px-1.5 py-0.5 text-xs font-medium", row_chain_tone(t.chain)]}
                  data-role="row-chain"
                >
                  {row_chain_label(t.chain)}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :trail, :map, required: true
  attr :consent_form, :any, required: true

  defp detail(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.link navigate={~p"/editor/governance"} class="text-sm text-base-content/60 hover:underline">
          &larr; {gettext("Governance")}
        </.link>
        <h1 class="mt-1 text-2xl font-semibold">{@trail.item.title}</h1>
        <p class="text-sm text-base-content/60">
          {@trail.item.type} · {@trail.item.state}
          <span :if={@trail.item.trashed?}> · {gettext("in the trash")}</span>
        </p>
        <.chain_badge
          chain={@trail.chain}
          gap_range={@trail.chain_gap_range}
          predates_fold_order?={@trail.predates_fold_order?}
        />
        <.witnessed_badge witnessed={@trail.witnessed} />
        <p :if={@trail.unanchored_tail > 0} class="mt-1 text-xs text-base-content/60">
          {gettext("%{count} edit(s) since the last anchor — covered at the next publish.",
            count: @trail.unanchored_tail
          )}
        </p>
        <div class="mt-3 flex gap-2">
          <a
            href={~p"/editor/governance/#{@trail.item.type}/#{@trail.item.id}/export.json"}
            class="btn btn-sm btn-default"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export trail (JSON)")}
          </a>
          <a
            href={~p"/editor/governance/#{@trail.item.type}/#{@trail.item.id}/export.csv"}
            class="btn btn-sm btn-default"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export trail (CSV)")}
          </a>
        </div>
      </div>

      <.lost_retractions_panel lost={@trail.lost_retractions} />

      <section class="space-y-3">
        <h2 class="text-lg font-medium">{gettext("Consent records")} ({length(@trail.consents)})</h2>
        <p :if={@trail.consents == []} class="text-sm text-base-content/60">
          {gettext("No consent recorded for this content.")}
        </p>
        <ul :if={@trail.consents != []} class="card divide-y divide-base-content/10 overflow-hidden">
          <li :for={c <- @trail.consents} class="p-3 text-sm">
            <span class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success">
              {c.kind}
            </span>
            <span :if={c.grantor} class="ml-2">{gettext("by")} {c.grantor}</span>
            <span :if={c.granted_at} class="ml-2 text-base-content/60">{when_str(c.granted_at)}</span>
            <code :if={c.reference} class="ml-2 text-xs text-base-content/60">{c.reference}</code>
          </li>
        </ul>

        <%!-- Record a consent without leaving the dashboard (#352). Stores a
              *reference* to the clearing document, never the document itself. --%>
        <details class="card p-3">
          <summary class="cursor-pointer text-sm font-medium">
            {gettext("Record a consent")}
          </summary>
          <.form
            for={@consent_form}
            id="record-consent-form"
            phx-submit="record_consent"
            class="mt-3 grid gap-2 sm:grid-cols-2"
          >
            <label class="text-xs">
              {gettext("Kind")}
              <select name="consent[kind]" class="field-select mt-1 w-full py-1" required>
                <option :for={kind <- KilnCMS.CMS.Consent.kinds()} value={kind}>{kind}</option>
              </select>
            </label>
            <label class="text-xs">
              {gettext("Reference (ticket / document id)")}
              <input name="consent[reference]" class="field-input mt-1 w-full py-1" />
            </label>
            <label class="text-xs">
              {gettext("Grantor")}
              <input name="consent[grantor]" class="field-input mt-1 w-full py-1" />
            </label>
            <label class="text-xs">
              {gettext("Note")}
              <input name="consent[note]" class="field-input mt-1 w-full py-1" />
            </label>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Record consent")}</.button>
            </div>
          </.form>
        </details>
      </section>

      <.transitions_panel transitions={@trail.transitions} />

      <section class="space-y-3">
        <h2 class="text-lg font-medium">{gettext("Version timeline")}</h2>
        <p :if={@trail.timeline == []} class="text-sm text-base-content/60">
          {gettext("No versions recorded.")}
        </p>
        <div :if={@trail.timeline != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Action")}</th>
                <th>{gettext("Who")}</th>
                <th>{gettext("Changed")}</th>
                <th>{gettext("Point in time")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @trail.timeline}>
                <td class="whitespace-nowrap text-base-content/70">{when_str(e.at)}</td>
                <td>
                  <span class={[
                    "rounded px-1.5 py-0.5 text-xs font-medium",
                    e.publish? && "bg-primary/15 text-primary-ink",
                    !e.publish? && "bg-base-200 text-base-content/70"
                  ]}>
                    {e.action}
                  </span>
                </td>
                <%!-- "Who" (#352): the acting user on the version, when the
                      write carried one (older versions predate attribution). --%>
                <td class="whitespace-nowrap text-xs text-base-content/70">
                  {e.actor || "—"}
                </td>
                <td class="max-w-md text-xs text-base-content/60">
                  <details :if={e.diffs != []}>
                    <summary class="cursor-pointer truncate">
                      {e.diffs |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}
                    </summary>
                    <%!-- Side-by-side old → new per changed field (#352). --%>
                    <dl class="mt-2 space-y-1">
                      <div
                        :for={{field, {old, new}} <- e.diffs}
                        class="grid grid-cols-[8rem_1fr] gap-2"
                      >
                        <dt class="truncate font-medium">{field}</dt>
                        <dd class="min-w-0">
                          <span class="block truncate text-error/80 line-through">{diff_value(old)}</span>
                          <span class="block truncate text-success">{diff_value(new)}</span>
                        </dd>
                      </div>
                    </dl>
                  </details>
                  <span :if={e.diffs == []}>—</span>
                </td>
                <td>
                  <%!-- Point-in-time delivery (#338) now covers dynamic (D17)
                        entries too, so every publish row links. --%>
                  <a
                    :if={e.publish?}
                    href={point_in_time_url(@trail.item, e.at)}
                    class="text-xs text-primary-ink hover:underline"
                    target="_blank"
                    rel="noopener"
                  >
                    {gettext("View as of then")}
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
