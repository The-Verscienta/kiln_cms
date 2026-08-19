defmodule KilnCMSWeb.ViewTracking do
  @moduledoc """
  Records a privacy-first view for a document Kiln has just delivered.

  Shared by the two surfaces that serve published content to a reader:
  `KilnCMSWeb.ContentController` (server-rendered HTML) and
  `KilnCMSWeb.ArtifactController` (headless `GET /api/content/:type/:slug`).
  Without the headless path a decoupled front end reports zero views — the
  visitor's browser never touches Kiln, so the artifact fetch is the only
  delivery event Kiln can observe. It is observed **server-side**: no beacon,
  no cookie, no client JS (`docs/advanced-analytics-plan.md`).

  What a view *means* therefore differs by surface, and the difference is real
  rather than cosmetic. On `:html` it is one rendered page. On the headless
  surfaces it is one **artifact fetch**, which is a floor and not a census: a
  front end with its own caching (ISR, a CDN, a static build) fetches once and
  then serves that document to many readers, while a build-time fetch counts a
  deploy that no one may ever read. The `surface` telemetry tag keeps the two
  apart in a metrics sink; the stored counters in `KilnCMS.Analytics` have no
  surface dimension and sum them.
  """

  alias KilnCMS.Analytics
  alias KilnCMSWeb.ReferrerSource

  # Bounds the `surface` metric tag. The delivery controllers only pass a
  # validated surface name, but this is a Prometheus label: an unrecognized
  # value collapses to "other" rather than minting a series per input.
  @surface_names Map.keys(KilnCMS.Firing.Surfaces.name_map())

  @typedoc """
  Which delivery surface served the document: `:html` for the rendered site,
  otherwise a fired-surface name (`"json"`, `"json_ld"`, `"web"`, `"llm"`).
  """
  @type surface :: :html | String.t()

  @doc """
  Record a view of `id` (a document of `type`, owned by `org_id`) served over
  `surface`, from the request `conn` that served it.

  Best-effort and **off the request path**: the upsert runs in a supervised,
  unlinked task so a slow DB pool (or a crawler spike) can't queue delivery.
  The supervisor's `max_children` bounds concurrent tasks, so a spike drops
  views (`start_child` → `{:error, :max_children}`) rather than exhausting the
  pool. Failures are swallowed.

  `:async_analytics` is on in prod/dev but off under test, where the detached
  task would run outside the ExUnit SQL sandbox connection (leaking a
  connection past the owning test and racing assertions). Running it inline
  keeps the upsert on the request's sandbox-owned connection.

  When referrer attribution is enabled (`KilnCMS.Analytics.referrers_enabled?/0`,
  #619), the `referer` header is read and classified **here**, before the task
  boundary — the raw header must never cross into the spawned closure. Off by
  default, the header is never even read: zero added work on the hot path.
  """
  @spec track(Plug.Conn.t(), surface(), String.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def track(conn, surface, type, id, org_id) do
    # Emitted synchronously, before the task branch, and independently of
    # `:async_analytics`: it is an in-process dispatch with no IO, it stays
    # inside the request's OTel span, and it still fires when the supervisor
    # sheds the DB write below ({:error, :max_children}) — so the event tracks
    # real traffic rather than DB capacity, and a divergence from the stored
    # counters is itself the backpressure signal. Emitting from an Ash hook
    # instead would give the changeset an after_action and so wrap every public
    # page view in a transaction (KilnCMS.Repo.prefer_transaction? is false).
    :telemetry.execute(
      [:kiln_cms, :analytics, :view],
      %{count: 1},
      # `content_id` is metadata only and is deliberately NOT a metric tag — one
      # Prometheus series per content item would be unbounded. No org_id: this
      # metadata can reach Sentry/OTLP exporters (see KilnCMS.Mail).
      %{type: type, content_id: id, surface: surface_tag(surface)}
    )

    source = referrer_source(conn)

    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
        record(type, id, org_id, source)
      end)
    else
      record(type, id, org_id, source)
    end

    :ok
  end

  # nil when the gate is off — record/4 then skips the third upsert entirely,
  # so a disabled deployment does no extra header read, no URI.parse, no extra
  # write. See KilnCMSWeb.ReferrerSource for the classification itself.
  defp referrer_source(conn) do
    if Analytics.referrers_enabled?() do
      referer = conn |> Plug.Conn.get_req_header("referer") |> List.first()
      ReferrerSource.classify(referer, conn.host)
    end
  end

  # Counters land in the viewed record's own site (epic #336): the all-time
  # total, today's bucket, and (when enabled) today's referrer bucket. Three
  # independent single-row upserts sharing one supervised task — deliberately
  # not wrapped in a transaction, which would hold the hot totals row's lock
  # across every statement and lower its throughput ceiling. Sharing the task
  # also means overload drops them together, so they under-count consistently
  # instead of drifting apart.
  #
  # `authorize?: false`: system-side bookkeeping on the delivery path — no actor
  # (anonymous readers), tenant pinned to the viewed record's own org, and the
  # `:record` policies on the three counters are `forbid_if always()` — only
  # the counters' `OrgAdmin` bypass could pass, and a reader is not one.
  defp record(type, id, org_id, source) do
    opts = [authorize?: false, tenant: org_id]
    Analytics.record_view(type, id, opts)
    Analytics.record_view_day(type, id, opts)
    if source, do: Analytics.record_referrer(type, id, source, opts)
  rescue
    _ -> :ok
  end

  defp surface_tag(:html), do: "html"
  defp surface_tag(name) when name in @surface_names, do: name
  defp surface_tag(_other), do: "other"
end
