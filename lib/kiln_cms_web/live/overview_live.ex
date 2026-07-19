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

    rows = content_rows(actor, org)
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
    |> assign(:types_count, length(ContentTypes.all()) + length(ContentTypes.dynamic_all()))
    |> assign(:plugins_count, length(Kiln.Plugins.all()))
    |> assign(:fields_count, if(admin?, do: count(FieldDefinition, actor, org)))
    |> assign(:webhooks, if(admin?, do: webhook_health(actor, org)))
    |> assign(:forms, if(admin?, do: form_activity(actor, org)))
    |> assign(:keys_count, if(admin?, do: count(ApiKey, actor, org)))
  end

  # One narrow-select fetch per content type; every content-shaped metric
  # (state counts, schedule window, staleness, translation coverage) is then
  # computed in memory from the same rows.
  defp content_rows(actor, org) do
    for ct <- ContentTypes.all() ++ ContentTypes.dynamic_all(),
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
                  Map.get(@by_state, :in_review, 0) == 0 and @stale == 0 and @upcoming == 0 and
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
