defmodule KilnCMS.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    assert_dev_routes_disabled_in_prod!()
    setup_observability()

    # Log Oban job lifecycle/exceptions. Without this, a failing delivery job
    # (e.g. a misconfigured mailer in prod) fails and retries silently — only
    # visible by querying `oban_jobs`. Attaching here makes those failures
    # show up in the logs, as the mailer config comment in runtime.exs assumes.
    _ = Oban.Telemetry.attach_default_logger(level: :info)
    warn_if_no_mailer_in_prod()

    # Ensure custom AshPhoenix form error impls (e.g. for StaleRecord) are
    # loaded so they register with the protocol and prevent unhandled errors.
    _ = Code.ensure_loaded(KilnCMSWeb.AshFormErrors)

    children = [
      KilnCMSWeb.Telemetry,
      # Reclaim stale rate-limit buckets so an IP-rotating flood can't grow the
      # ETS table without bound (one row per `bucket:IP` otherwise lives forever).
      {KilnCMSWeb.RateLimit, clean_period: :timer.minutes(1), key_older_than: :timer.minutes(5)},
      # Bounded LRW content cache (see `KilnCMS.Cache.child_spec/1`).
      KilnCMS.Cache,
      # Bounded LRW firing-artifact cache (see `KilnCMS.Firing.Cache.child_spec/1`).
      KilnCMS.Firing.Cache,
      KilnCMS.Repo,
      {DNSCluster, query: Application.get_env(:kiln_cms, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:kiln_cms, :ash_domains),
         oban_config()
       )},
      {Phoenix.PubSub, name: KilnCMS.PubSub},
      # Fire-and-forget tasks off the request hot path (best-effort page-view
      # analytics, search-query recording) so a DB write can't queue/slow
      # delivery. `max_children` bounds in-flight tasks: under a crawler/traffic
      # spike, excess best-effort writes are dropped instead of spawning without
      # limit and exhausting the DB pool (start_child returns {:error,
      # :max_children}, which callers treat as a dropped sample).
      {Task.Supervisor, name: KilnCMS.TaskSupervisor, max_children: 50},
      KilnCMSWeb.Presence,
      KilnCMS.Collab.Locks,
      # Collaborative-editing CRDT prototype (KilnCMS.Collab.Crdt): one
      # DocServer per open document, registered by channel topic. Idle-cheap —
      # servers only exist while editors are attached (+ a grace period).
      {Registry, keys: :unique, name: KilnCMS.Collab.Crdt.Registry},
      {DynamicSupervisor, name: KilnCMS.Collab.Crdt.DocSupervisor, strategy: :one_for_one},
      # Start a worker by calling: KilnCMS.Worker.start_link(arg)
      # {KilnCMS.Worker, arg},
      # Start to serve requests, typically the last entry
      KilnCMSWeb.Endpoint,
      {Absinthe.Subscription, KilnCMSWeb.Endpoint},
      {AshAuthentication.Supervisor, [otp_app: :kiln_cms]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: KilnCMS.Supervisor]

    Supervisor.start_link(
      children ++
        subscription_batcher() ++
        embedding_children() ++ reranker_children() ++ Kiln.Plugins.children(),
      opts
    )
  end

  # The core Oban config with plugin queues merged in (D18) — plugins declare
  # queues in code (`oban_queues/0`) instead of editing the host's config.
  defp oban_config do
    Application.fetch_env!(:kiln_cms, Oban)
    |> Keyword.update(:queues, Kiln.Plugins.oban_queues(), fn queues ->
      Keyword.merge(Kiln.Plugins.oban_queues(), queues)
    end)
  end

  # Wire up production observability. Both halves are no-ops unless configured,
  # so dev/test/precommit pay nothing and never reach a collector:
  #
  #   * OpenTelemetry tracing — attached only when OTEL_EXPORTER_OTLP_ENDPOINT is
  #     set (config/runtime.exs flips `:otel_enabled`). Instruments the HTTP
  #     server (Bandit), Phoenix + LiveView, Ecto queries, and Oban jobs. Ecto
  #     spans include the parameterized SQL (`db_statement: :enabled`) — safe
  #     because Ecto sends values as bound parameters, not inlined in the text.
  #   * Sentry — the logger handler that turns crashes into events is added only
  #     when SENTRY_DSN is set. Request context comes from `Sentry.PlugContext`
  #     in the endpoint; Oban errors via the built-in integration (config.exs).
  #     `Sentry.PlugCapture` is intentionally NOT used: on Bandit it double-reports.
  defp setup_observability do
    if Application.get_env(:kiln_cms, :otel_enabled, false) do
      OpentelemetryBandit.setup()
      OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)
      OpentelemetryEcto.setup([:kiln_cms, :repo], db_statement: :enabled)
      OpentelemetryOban.setup()
    end

    if Application.get_env(:sentry, :dsn) do
      _ =
        :logger.add_handler(:kiln_sentry_handler, Sentry.LoggerHandler, %{
          config: %{metadata: [:file, :line]}
        })
    end

    :ok
  end

  # Fail fast if a :prod release was built with `dev_routes` enabled — that would
  # expose AshAdmin (`/admin`, with an actor picker that can impersonate :admin),
  # LiveDashboard, and the Swoosh mailbox with no authentication. dev_routes is
  # compile-keyed (only config/dev.exs sets it), so this catches a mis-built
  # release rather than a legitimate dev/test boot.
  defp assert_dev_routes_disabled_in_prod! do
    if Application.get_env(:kiln_cms, :compile_env) == :prod and
         Application.get_env(:kiln_cms, :dev_routes) do
      raise """
      Refusing to boot: `dev_routes` is enabled in a :prod release.

      This exposes /admin (AshAdmin), LiveDashboard, and the Swoosh mailbox
      without authentication. Rebuild the release without `config :kiln_cms,
      dev_routes: true` (it should only ever be set in config/dev.exs).
      """
    end
  end

  # Warn loudly at boot if a :prod release has no real mailer configured. All
  # outbound mail is queued, so registration/reset requests now *succeed* even
  # with no adapter (the Local adapter's storage process isn't started in a
  # release, so every delivery job just fails and retries) — which means a
  # missing MAIL_MODE/SMTP_HOST is otherwise silent. A warning (not a hard
  # raise) keeps genuinely mail-less deployments bootable.
  defp warn_if_no_mailer_in_prod do
    adapter = Application.get_env(:kiln_cms, KilnCMS.Mailer, [])[:adapter]

    if Application.get_env(:kiln_cms, :compile_env) == :prod and
         adapter in [nil, Swoosh.Adapters.Local] do
      require Logger

      Logger.warning(
        "No mail delivery is configured (MAIL_MODE / SMTP_HOST unset). Outbound " <>
          "email — confirmations, password resets, notifications — will be queued " <>
          "but never delivered. Set MAIL_MODE=smtp (with SMTP_HOST) or MAIL_MODE=direct."
      )
    end
  end

  # The embedding serving is only started when semantic search is enabled with
  # the local Bumblebee adapter — loading the model is expensive, so the default
  # install (and any deployment using a remote embedder) skips it entirely.
  # GraphQL subscription resolution batches through this out-of-band worker in
  # prod. In test it is off: AshGraphql then falls back to resolving in the
  # publishing process, which keeps reads on the test's sandbox connection.
  defp subscription_batcher do
    if Application.get_env(:kiln_cms, :start_subscription_batcher, true),
      do: [AshGraphql.Subscription.Batcher],
      else: []
  end

  defp embedding_children do
    if KilnCMS.Search.semantic?() and
         KilnCMS.Search.embedder() == KilnCMS.Search.Embedder.Bumblebee do
      [
        {Nx.Serving,
         serving: KilnCMS.Search.Serving.build(),
         name: KilnCMS.Search.Serving.name(),
         batch_timeout: 50}
      ]
    else
      []
    end
  end

  # The reranker serving is only started when reranking is enabled with the
  # local Bumblebee adapter (same gating as the embedder).
  defp reranker_children do
    if KilnCMS.Search.rerank?() and
         KilnCMS.Search.reranker() == KilnCMS.Search.Reranker.Bumblebee do
      [
        {Nx.Serving,
         serving: KilnCMS.Search.RerankerServing.build(),
         name: KilnCMS.Search.RerankerServing.name(),
         batch_timeout: 50}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KilnCMSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
