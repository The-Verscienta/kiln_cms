defmodule KilnCMSWeb.OverviewLive do
  @moduledoc """
  Console home (`/editor/overview`) — the site at a glance, laid out as the
  bagua's later-heaven square: content in the centre (the taiji; in feng shui
  the centre is health, so the tile carries the content-health nudges), and
  the eight supporting domains around it, each tile marked with its trigram
  and carrying one headline number plus a link into its surface.

  The arrangement is also the product's name read in trigrams: kun ☷ (earth,
  the receptive store of raw material) worked by li ☲ (fire, illumination) —
  clay and firing, a kiln. Editor/admin only; numbers that only admin
  policies can read render as “—” for editors.
  """
  use KilnCMSWeb, :live_view

  require Ash.Query

  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  alias KilnCMS.CMS.{
    Category,
    FieldDefinition,
    Form,
    FormSubmission,
    MediaItem,
    Tag,
    WebhookDelivery
  }

  alias KilnCMS.I18n

  require Logger

  # Published this long ago with no edit since → the centre tile's "stale"
  # nudge (same heuristic family as translation staleness: updated_at only).
  @stale_days 90
  # "Coming up": scheduled publish/unpublish transitions within the next week.
  @window_days 7

  # Only what the metrics need — never the blocks tree or embeddings.
  @row_fields [:id, :state, :slug, :locale, :updated_at, :scheduled_at, :unpublish_at]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:admin?, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     # A separate, stricter question from `:admin?` — see the backup strip in
     # `render/1`. Backups are instance-wide, so the panel this strip links to
     # takes a platform admin (#1160); gating the strip on the per-org tier
     # would advertise a page the reader cannot open.
     |> assign(:platform_admin?, KilnCMSWeb.LiveUserAuth.platform_admin?(socket))
     |> assign_backup_warning()
     |> assign_blocked_experiments()
     |> assign(:page_title, gettext("Overview"))
     |> load_metrics()}
  end

  defp load_metrics(socket) do
    actor = socket.assigns.actor
    # Every count/aggregate scopes to the current site (epic #336); Ash ignores
    # the tenant on the still-global resources (API keys, analytics).
    org = socket.assigns.current_org
    admin? = socket.assigns.admin?
    now = DateTime.utc_now()

    # The dynamic half of the registry is per-org (epic #336), so it has to be
    # asked for THIS site's types — the arity-0 default resolves the default
    # org, which on a multi-site install is the wrong site's custom types.
    types = ContentTypes.all_for_org(org.id)

    rows = content_rows(types, actor, org)
    by_state = Enum.frequencies_by(rows, fn {_kind, r} -> r.state end)

    socket
    |> assign(:total, length(rows))
    |> assign(:by_state, by_state)
    |> assign(:stale, stale_count(rows, now))
    |> assign(:upcoming, upcoming_count(rows, now))
    |> assign(:coverage, coverage(rows))
    |> assign(:media_count, count(MediaItem, actor, org))
    |> assign(:views, total_views(actor, org))
    |> assign(:taxonomy_terms, count(Category, actor, org) + count(Tag, actor, org))
    |> assign(:types_count, length(types))
    |> assign(:plugins_count, length(Kiln.Plugins.all()))
    |> assign(:fields_count, if(admin?, do: count(FieldDefinition, actor, org)))
    |> assign(:webhooks, if(admin?, do: webhook_health(actor, org)))
    |> assign(:forms, if(admin?, do: form_activity(actor, org)))
    |> assign(:keys_count, if(admin?, do: count(ApiKey, actor, org)))
    |> assign(
      :my_open_tasks,
      length(CMS.list_tasks_for_assignee!(actor.id, actor: actor, tenant: org))
    )
  end

  # One narrow-select fetch per content type; every content-shaped metric
  # (state counts, schedule window, staleness, translation coverage) is then
  # computed in memory from the same rows.
  defp content_rows(types, actor, org) do
    for ct <- types,
        row <- ContentTypes.list!(ct, actor: actor, tenant: org, query: [select: @row_fields]) do
      {ct.type, row}
    end
  end

  defp stale_count(rows, now) do
    Enum.count(rows, fn {_kind, r} ->
      r.state == :published and DateTime.diff(now, r.updated_at, :day) >= @stale_days
    end)
  end

  defp upcoming_count(rows, now) do
    horizon = DateTime.add(now, @window_days, :day)

    Enum.count(rows, fn {_kind, r} ->
      (r.state in [:draft, :in_review] and in_window?(r.scheduled_at, now, horizon)) or
        (r.state == :published and in_window?(r.unpublish_at, now, horizon))
    end)
  end

  defp in_window?(nil, _now, _horizon), do: false

  defp in_window?(at, now, horizon),
    do: DateTime.after?(at, now) and DateTime.before?(at, horizon)

  # Site-wide translation coverage: of every {kind, slug} group, the share
  # with a variant in each configured locale. nil on single-locale sites (and
  # on empty sites), which the xun tile renders as “—”.
  defp coverage(rows) do
    locales = I18n.locales()

    with true <- length(locales) > 1,
         groups when map_size(groups) > 0 <-
           Enum.group_by(rows, fn {kind, r} -> {kind, r.slug} end, fn {_kind, r} -> r.locale end) do
      covered = Enum.count(groups, fn {_key, ls} -> Enum.all?(locales, &(&1 in ls)) end)
      total = map_size(groups)
      %{pct: round(covered * 100 / total), covered: covered, total: total}
    else
      _ -> nil
    end
  end

  defp webhook_health(actor, org) do
    endpoints = CMS.list_webhook_endpoints!(actor: actor, tenant: org)

    failed_24h =
      WebhookDelivery
      |> Ash.Query.filter(status == :failed and inserted_at >= ago(1, :day))
      |> count(actor, org)

    %{
      active: Enum.count(endpoints, & &1.active),
      disabled: Enum.count(endpoints, &(&1.auto_disabled_at != nil)),
      failed_24h: failed_24h
    }
  end

  defp form_activity(actor, org) do
    recent =
      FormSubmission
      |> Ash.Query.filter(inserted_at >= ago(^@window_days, :day))
      |> count(actor, org)

    %{forms: count(Form, actor, org), recent: recent}
  end

  defp count(query, actor, org) do
    case Ash.count(query, actor: actor, tenant: org) do
      {:ok, n} -> n
      _ -> 0
    end
  end

  # SUM over zero rows yields nil (see AnalyticsLive.total_views/1 for why
  # this is a pattern match rather than `|| 0`). `tenant` is a no-op until
  # Analytics.ContentView is org-scoped (PR 4d); harmless under the guard.
  defp total_views(actor, org) do
    case Ash.sum(KilnCMS.Analytics.ContentView, :views, actor: actor, tenant: org) do
      {:ok, total} when is_integer(total) -> total
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tiles, tiles(assigns))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={gettext("Overview")}
      active={:overview}
    >
      <div class="space-y-5">
        <div>
          <h1 class="text-xl font-semibold tracking-tight">{gettext("Overview")}</h1>
          <p class="text-sm text-base-content/60">
            {gettext("The site at a glance — eight domains arranged around your content.")}
          </p>
        </div>

        <%!-- Stale-backup warning (#484). A strip above the grid rather than a
              ninth tile: the bagua is a fixed 3×3 with the centre taken, so
              there is no ninth position — and this is an alert, which wants to
              be read before the eight steady-state numbers rather than
              alongside them.

              Platform-admin only, matching `/editor/backups` — and note that
              is a STRICTER test than `@admin?`, which is the per-org tier
              (#1160). A backup covers the whole instance, so an admin of one
              site can neither take one nor open the panel this strip links to;
              showing it to them would report on someone else's infrastructure
              and lead to a page that turns them away. An editor can't act on
              it either and shouldn't be told the deployment is unprotected.
              Absent entirely when backups are healthy — a permanent green
              banner is one nobody reads, and its absence is what makes the red
              one land. --%>
        <.overview_strip
          :if={@platform_admin? and @backup_alarming?}
          id="overview-backup-warning"
          navigate={~p"/editor/backups"}
          tone_class="border-error/30 bg-error/5 hover:bg-error/10"
          icon="hero-exclamation-triangle"
          icon_class="text-error"
        >
          <span class="block text-sm font-medium">{@backup_headline}</span>
          <span class="block text-xs text-base-content/70">
            {gettext("Open Backups to check the schedule or take one now.")}
          </span>
        </.overview_strip>

        <%!-- An experiment that cannot convert (#1008). Distinct from the
              backup strip above and deliberately a *warning*, not an error: the
              site is fine, the measurement is not. Admin-only for the same
              reason — the fixes are a config flag or a deleted goal document,
              neither of which an editor can act on. That gate lives in
              `assign_blocked_experiments/1`, where it also saves an editor the
              queries; the list is empty for them, so there is nothing to
              re-check here.

              Absent when every running experiment is healthy, and absent
              entirely on a site with none. --%>
        <.overview_strip
          :if={@experiments_off? or @blocked_experiments != []}
          id="overview-experiment-warning"
          tone_class="border-warning/30 bg-warning/5"
          icon="hero-beaker"
          icon_class="text-warning-ink"
        >
          <%!-- The deployment switch is site-wide, so it is said once, here,
                rather than repeated under every experiment (#1008 review). --%>
          <span :if={@experiments_off?} class="block text-sm font-medium">
            {gettext("Experiments are switched off for this deployment, so no arm is served.")}
          </span>
          <%!-- NOT "cannot convert": the reasons below do not share an outcome
                — some mean nothing converts, and `:goal_is_self` means a goal
                that would convert its own impression if delivery let it. What
                they share is that the numbers are not a result. --%>
          <span :if={@blocked_experiments != []} class="block text-sm font-medium">
            {ngettext(
              "%{count} running experiment is not producing usable results.",
              "%{count} running experiments are not producing usable results.",
              length(@blocked_experiments)
            )}
          </span>
          <ul class="mt-1 space-y-0.5 text-xs text-base-content/70">
            <li :for={{name, reason} <- @blocked_experiments}>
              <span class="font-medium">{name}</span> — {blocked_headline(reason)}
            </li>
          </ul>
        </.overview_strip>

        <div class="grid gap-4 lg:grid-cols-3">
          <div
            id="bagua-center"
            class="card card-pad flex flex-col gap-2 border-primary/30 bg-primary/5 lg:col-start-2 lg:row-start-2"
          >
            <div class="flex items-center justify-between text-base-content/50">
              <svg viewBox="0 0 14 14" class="h-3.5 w-3.5" role="img" aria-label={gettext("centre")}>
                <title>{gettext("centre")}</title>
                <circle cx="7" cy="7" r="5.5" fill="none" stroke="currentColor" stroke-width="2" />
              </svg>
              <span class="text-xs">{gettext("taiji · centre")}</span>
            </div>
            <p class="text-xs font-medium uppercase tracking-wide text-base-content/70">
              {gettext("Content")}
            </p>
            <p id="overview-total" class="text-3xl font-semibold tabular-nums">{@total}</p>
            <p class="text-xs text-base-content/60">
              {gettext("%{published} published · %{in_review} in review · %{draft} drafts",
                published: Map.get(@by_state, :published, 0),
                in_review: Map.get(@by_state, :in_review, 0),
                draft: Map.get(@by_state, :draft, 0)
              )}
            </p>
            <ul class="mt-1 space-y-1 text-xs">
              <li :if={@my_open_tasks > 0}>
                <.link navigate={~p"/editor/tasks"} class="text-primary hover:underline">
                  {ngettext(
                    "%{count} task assigned to you",
                    "%{count} tasks assigned to you",
                    @my_open_tasks,
                    count: @my_open_tasks
                  )}
                </.link>
              </li>
              <li :if={Map.get(@by_state, :in_review, 0) > 0}>
                <.link navigate={~p"/editor?status=in_review"} class="text-primary hover:underline">
                  {gettext("%{count} waiting for review", count: Map.get(@by_state, :in_review, 0))}
                </.link>
              </li>
              <li :if={@stale > 0}>
                <.link navigate={~p"/editor?status=published"} class="text-primary hover:underline">
                  {gettext("%{count} published untouched for %{days}+ days",
                    count: @stale,
                    days: 90
                  )}
                </.link>
              </li>
              <li :if={@upcoming > 0}>
                <.link navigate={~p"/editor/calendar"} class="text-primary hover:underline">
                  {gettext("%{count} scheduled this week", count: @upcoming)}
                </.link>
              </li>
              <li :if={@webhooks && @webhooks.failed_24h > 0}>
                <.link navigate={~p"/editor/webhooks"} class="text-primary hover:underline">
                  {gettext("%{count} webhook failures in 24h", count: @webhooks.failed_24h)}
                </.link>
              </li>
              <li
                :if={
                  @my_open_tasks == 0 and Map.get(@by_state, :in_review, 0) == 0 and
                    @stale == 0 and @upcoming == 0 and
                    (is_nil(@webhooks) or @webhooks.failed_24h == 0)
                }
                class="text-base-content/50"
              >
                {gettext("All quiet.")}
              </li>
            </ul>
            <.link
              navigate={~p"/editor"}
              class="mt-auto pt-1 text-xs font-medium text-primary hover:underline"
            >
              {gettext("Open content")} <span aria-hidden="true">→</span>
            </.link>
          </div>

          <.tile :for={tile <- @tiles} tile={tile} />
        </div>
      </div>
    </Layouts.console>
    """
  end

  attr :tile, :map, required: true

  defp tile(assigns) do
    ~H"""
    <div id={"bagua-#{@tile.key}"} class={["card card-pad flex flex-col gap-2", @tile.pos]}>
      <div class="flex items-center justify-between text-base-content/50">
        <.trigram lines={@tile.lines} label={@tile.name} />
        <span class="text-xs">{@tile.name}</span>
      </div>
      <p class="text-xs font-medium uppercase tracking-wide text-base-content/70">{@tile.title}</p>
      <p class="text-3xl font-semibold tabular-nums">{@tile.value || "—"}</p>
      <p :if={@tile.subtitle} class="text-xs text-base-content/60">{@tile.subtitle}</p>
      <.link
        :if={@tile.path}
        navigate={@tile.path}
        aria-label={gettext("Open %{title}", title: @tile.title)}
        class="mt-auto pt-1 text-xs font-medium text-primary hover:underline"
      >
        {gettext("Open")} <span aria-hidden="true">→</span>
      </.link>
    </div>
    """
  end

  # The eight outer tiles in the later-heaven arrangement (south at the top,
  # as on a classical bagua): grid positions are fixed per trigram, values
  # come from the metrics. `value: nil` renders as “—” (admin-only numbers
  # seen by an editor, or coverage on a single-locale site).
  @tile_order [:xun, :li, :kun, :zhen, :dui, :gen, :kan, :qian]

  # Only the name and the reason atom reach the socket — never the experiment
  # structs, which carry every variant's patch. The English sentence
  # `Health.blocked_reason/1` also returns is for the terminal; this surface
  # phrases its own so the strip translates (#1008).
  #
  # `experiments_off?` is the site-wide half, kept separate from the per-row
  # reasons: `Health` deliberately no longer folds the deployment switch into a
  # per-experiment verdict, because doing so said the same thing on every row
  # and hid the real reasons behind it.
  defp assign_blocked_experiments(socket) do
    if socket.assigns.admin? do
      org_id = socket.assigns.current_org.id

      # Back through `Experiments.blocked/1` rather than re-deriving it here
      # (#1114): it is the single entry point, and it short-circuits when the
      # deployment switch is off so a disabled site pays neither the
      # running-set load nor a lookup per experiment. `switched_off?/1` is the
      # site-wide half, and reads the same cache.
      socket
      |> assign(
        :blocked_experiments,
        Enum.map(KilnCMS.Experiments.blocked(org_id), &blocked_row/1)
      )
      |> assign(:experiments_off?, KilnCMS.Experiments.switched_off?(org_id))
    else
      socket
      |> assign(:blocked_experiments, [])
      |> assign(:experiments_off?, false)
    end
  rescue
    # The overview must render even when the experiments layer cannot answer.
    # Same posture as `Experiments.running/1`, and logged for the same reason.
    error ->
      Logger.warning("Overview could not check experiment health: #{Exception.message(error)}")

      socket
      |> assign(:blocked_experiments, [])
      |> assign(:experiments_off?, false)
  end

  # Restored to the function it documents — a later insertion split it from
  # `assign_backup_warning/1` and left this reading as though the experiment
  # check were the cheap one (#1008 review).
  #
  # Reads the backup manifest — one small file, no query. Computed at mount
  # rather than per render, and only the two values the strip needs, so the
  # whole `Backups.status/0` map isn't held in the socket for a banner that is
  # usually absent.

  attr :id, :string, required: true
  attr :icon, :string, required: true

  attr :tone_class, :string,
    required: true,
    doc: """
    Border/background utilities, passed as a LITERAL from the call site. Not
    built from a tone name: Tailwind's JIT only emits a class it can see spelled
    out in source, so an interpolated `border-<tone>/30` would compile to markup with no CSS
    behind it (#1116).
    """

  attr :icon_class, :string, required: true
  attr :navigate, :string, default: nil
  slot :inner_block, required: true

  # An alert strip above the bagua grid.
  #
  # A strip rather than a ninth tile: the grid is a fixed 3×3 with the centre
  # taken, and an alert wants to be read before the eight steady-state numbers
  # rather than alongside them.
  #
  # Rendered as a link when `navigate` is given and a plain `div` otherwise —
  # which is the one place the two strips legitimately differ, so the hover
  # state belongs to the navigable variant only rather than being an
  # inconsistency to reconcile.
  defp overview_strip(assigns) do
    ~H"""
    <.link
      :if={@navigate}
      id={@id}
      navigate={@navigate}
      class={["flex items-start gap-3 rounded-lg border p-4", @tone_class]}
    >
      <.icon name={@icon} class={["mt-0.5 size-5 shrink-0", @icon_class]} />
      <span class="min-w-0">{render_slot(@inner_block)}</span>
    </.link>
    <div
      :if={is_nil(@navigate)}
      id={@id}
      class={["flex items-start gap-3 rounded-lg border p-4", @tone_class]}
    >
      <.icon name={@icon} class={["mt-0.5 size-5 shrink-0", @icon_class]} />
      <div class="min-w-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  # Only the name and the reason atom reach the socket — never the experiment
  # struct, which carries every variant's patch. The English sentence
  # `blocked_reason/1` also returns is for the terminal; this surface phrases
  # its own so the strip translates.
  defp blocked_row({experiment, {reason, _sentence}}), do: {experiment.name, reason}

  defp blocked_headline(:sticky_off),
    do: gettext("its goal converts on a later page, and sticky assignment is off")

  defp blocked_headline(:no_goal_form), do: gettext("no goal form is set")
  defp blocked_headline(:goal_form_missing), do: gettext("its goal form has been deleted")
  defp blocked_headline(:no_target), do: gettext("no goal document is set")
  defp blocked_headline(:no_goal_funnel), do: gettext("no goal funnel is set")

  defp blocked_headline(:goal_is_self),
    do: gettext("its goal document is the experimented document itself")

  defp blocked_headline(:goal_type_unknown),
    do: gettext("its goal content type is not a type on this site")

  defp blocked_headline(:goal_document_missing),
    do: gettext("its goal document has been deleted")

  defp blocked_headline(:funnel_ends_here),
    do: gettext("its funnel now ends on the experimented document itself")

  defp blocked_headline(:funnel_target_missing),
    do: gettext("its funnel no longer resolves to a document")

  defp blocked_headline(:document_missing),
    do: gettext("the document under test has been deleted")

  defp blocked_headline(:document_unpublished),
    do: gettext("the document under test is not published, so no arm is served")

  defp blocked_headline(:goal_document_unpublished),
    do: gettext("its goal document is not published")

  defp blocked_headline(:goal_form_inactive),
    do: gettext("its goal form is no longer accepting submissions")

  # "could not be read" is deliberately NOT "has been deleted": a pool timeout
  # and a deletion are the same tuple at the call site, and telling an admin a
  # form was removed sends them to restore something nobody touched.
  defp blocked_headline(:goal_unreadable),
    do: gettext("its goal could not be read — this may be temporary")

  defp blocked_headline(:unknown_goal),
    do: gettext("its goal is one this version cannot check")

  # Deliberately total: a reason added to `Health` and not here would otherwise
  # crash the overview, which is a worse outcome than a vaguer sentence.
  defp blocked_headline(_other), do: gettext("its goal can no longer be reached")

  defp assign_backup_warning(socket) do
    status = KilnCMS.Backups.status()

    socket
    # NOT `status.stale?` alone. A backup that failed five minutes ago is not
    # stale — it is recent and worthless — and gating on age let the overview
    # stay clean while `/editor/backups` said "The last backup failed". Same
    # trap as `BackupLive.alarming?/1`; it needed fixing in both places.
    |> assign(:backup_alarming?, status.stale? or failed?(status))
    |> assign(:backup_headline, backup_headline(status))
  end

  defp failed?(%{manifest: %{ok: false}}), do: true
  defp failed?(_status), do: false

  defp backup_headline(%{manifest: nil}),
    do: gettext("No backup has ever been recorded for this deployment.")

  defp backup_headline(%{manifest: %{ok: false}}),
    do: gettext("The last backup failed.")

  defp backup_headline(%{manifest: %{finished_at: %DateTime{} = at}}) do
    # Hours below a day: `DateTime.diff(:day)` truncates, so a deployment with
    # `BACKUP_STALE_AFTER_HOURS` under 24 rendered "The last backup was 0 days
    # ago" — a sentence that reads as a bug rather than a warning.
    hours = DateTime.diff(DateTime.utc_now(), at, :hour)

    if hours < 24 do
      ngettext(
        "The last backup was %{count} hour ago.",
        "The last backup was %{count} hours ago.",
        hours,
        count: hours
      )
    else
      days = div(hours, 24)

      ngettext(
        "The last backup was %{count} day ago.",
        "The last backup was %{count} days ago.",
        days,
        count: days
      )
    end
  end

  defp backup_headline(_status), do: gettext("The backup status can't be determined.")

  defp tiles(assigns), do: Enum.map(@tile_order, &tile_spec(&1, assigns))

  defp tile_spec(:xun, assigns) do
    %{
      key: :xun,
      name: "xun · wind",
      lines: [false, true, true],
      pos: "lg:col-start-1 lg:row-start-1",
      title: gettext("Translations"),
      value: assigns.coverage && "#{assigns.coverage.pct}%",
      subtitle:
        if(assigns.coverage,
          do:
            gettext("%{covered} of %{total} fully translated",
              covered: assigns.coverage.covered,
              total: assigns.coverage.total
            ),
          else: gettext("single-locale site")
        ),
      path: length(I18n.locales()) > 1 && ~p"/editor/translations"
    }
  end

  defp tile_spec(:li, assigns) do
    %{
      key: :li,
      name: "li · fire",
      lines: [true, false, true],
      pos: "lg:col-start-2 lg:row-start-1",
      title: gettext("Analytics & search"),
      value: assigns.views,
      subtitle: gettext("recorded content views"),
      path: ~p"/editor/analytics"
    }
  end

  defp tile_spec(:kun, assigns) do
    %{
      key: :kun,
      name: "kun · earth",
      lines: [false, false, false],
      pos: "lg:col-start-3 lg:row-start-1",
      title: gettext("Media"),
      value: assigns.media_count,
      subtitle: gettext("items in the library"),
      path: ~p"/media"
    }
  end

  defp tile_spec(:zhen, assigns) do
    %{
      key: :zhen,
      name: "zhen · thunder",
      lines: [true, false, false],
      pos: "lg:col-start-1 lg:row-start-2",
      title: gettext("Webhooks"),
      value: assigns.webhooks && assigns.webhooks.active,
      subtitle:
        assigns.webhooks &&
          gettext("%{failed} failed in 24h · %{disabled} auto-disabled",
            failed: assigns.webhooks.failed_24h,
            disabled: assigns.webhooks.disabled
          ),
      path: assigns.webhooks && ~p"/editor/webhooks"
    }
  end

  defp tile_spec(:dui, assigns) do
    %{
      key: :dui,
      name: "dui · lake",
      lines: [true, true, false],
      pos: "lg:col-start-3 lg:row-start-2",
      title: gettext("Forms"),
      value: assigns.forms && assigns.forms.forms,
      subtitle:
        assigns.forms && gettext("%{count} submissions this week", count: assigns.forms.recent),
      path: assigns.forms && ~p"/editor/forms"
    }
  end

  defp tile_spec(:gen, assigns) do
    %{
      key: :gen,
      name: "gen · mountain",
      lines: [false, false, true],
      pos: "lg:col-start-1 lg:row-start-3",
      title: gettext("Structure"),
      value: assigns.types_count,
      subtitle:
        if(assigns.fields_count,
          do:
            gettext("content types · %{fields} fields · %{terms} taxonomy terms",
              fields: assigns.fields_count,
              terms: assigns.taxonomy_terms
            ),
          else: gettext("content types · %{terms} taxonomy terms", terms: assigns.taxonomy_terms)
        ),
      path: if(assigns.fields_count, do: ~p"/editor/types", else: ~p"/editor/taxonomy")
    }
  end

  defp tile_spec(:kan, assigns) do
    %{
      key: :kan,
      name: "kan · water",
      lines: [false, true, false],
      pos: "lg:col-start-2 lg:row-start-3",
      title: gettext("Calendar"),
      value: assigns.upcoming,
      subtitle: gettext("transitions in the next 7 days"),
      path: ~p"/editor/calendar"
    }
  end

  defp tile_spec(:qian, assigns) do
    %{
      key: :qian,
      name: "qian · heaven",
      lines: [true, true, true],
      pos: "lg:col-start-3 lg:row-start-3",
      title: gettext("Settings & keys"),
      value: assigns.keys_count,
      subtitle:
        assigns.keys_count &&
          gettext("API keys · %{count} plugins active", count: assigns.plugins_count),
      path: if(assigns.keys_count, do: ~p"/editor/api-keys", else: ~p"/editor/settings")
    }
  end
end
