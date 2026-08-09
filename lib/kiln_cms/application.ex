defmodule KilnCMS.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    assert_dev_routes_disabled_in_prod!()
    setup_observability()
    # Strictly after `setup_observability/0` — that is where the Sentry logger
    # handler is attached, and reaching Sentry is the whole point (#634).
    KilnCMS.Config.Env.replay_collected()

    # Log Oban job lifecycle/exceptions. Without this, a failing delivery job
    # (e.g. a misconfigured mailer in prod) fails and retries silently — only
    # visible by querying `oban_jobs`. Attaching here makes those failures
    # show up in the logs, as the mailer config comment in runtime.exs assumes.
    _ = Oban.Telemetry.attach_default_logger(level: :info)
    warn_if_no_mailer_in_prod()
    warn_if_seo_drafting_egresses()
    warn_if_assist_egresses()
    warn_if_ask_egresses()

    # Ensure custom AshPhoenix form error impls (e.g. for StaleRecord) are
    # loaded so they register with the protocol and prevent unhandled errors.
    _ = Code.ensure_loaded(KilnCMSWeb.AshFormErrors)

    children = [
      KilnCMSWeb.Telemetry,
      # Reclaim stale rate-limit buckets so an IP-rotating flood can't grow the
      # ETS table without bound (one row per `bucket:IP` otherwise lives forever).
      {KilnCMSWeb.RateLimit, clean_period: :timer.minutes(1), key_older_than: :timer.minutes(5)},
      # Cooldown bucket for the aggregated "relay unreachable" mail alert — one
      # fixed key, so the table stays tiny; a periodic clean keeps it honest.
      {KilnCMS.Mail.RelayAlert, clean_period: :timer.minutes(5)},
      # Per-account auth budgets (#478). No `key_older_than`: the fixed-window
      # algorithm's cleaner deletes strictly on `expires_at`, and never reads
      # that option — setting it would be inert config that reads like a floor.
      {KilnCMS.Accounts.AccountThrottle, clean_period: :timer.minutes(5)},
      # Per-user and per-org spend ceilings for every optional LLM feature (SEO
      # drafting, block assist). Started unconditionally: the table is empty
      # until someone asks for a generation, and starting it lazily would mean
      # the first request raced the supervisor.
      {KilnCMS.LLM.Budget, clean_period: :timer.minutes(5)},
      # Per-domain pacing for the external link checker (#474). Keyed by remote
      # host, so the table grows with the number of distinct hosts a sweep
      # touches — cleaned on the same schedule as the rest.
      {KilnCMS.Links.Throttle, clean_period: :timer.minutes(5)},
      # Bounded LRW content cache (see `KilnCMS.Cache.child_spec/1`).
      KilnCMS.Cache,
      # Host→org resolution, on its own eviction schedule and the only cache
      # that remembers a miss (#659).
      KilnCMS.Cache.Hosts,
      # Content-addressed embedding vectors for the compute-on-demand path
      # (#852). Its OWN instance so an editing session cannot evict the
      # published records `Firing.Delivery` serves from during a DB outage
      # (#964).
      KilnCMS.Search.VectorCache,
      # Small dedicated store for in-flight WebAuthn challenges (#331) —
      # TTL-only, isolated from the content cache's busts/eviction pressure.
      # `child_spec/1` ids on the module, so a bare `{Cachex, …}` child needs an
      # explicit id: add a second one without it and the supervisor refuses to
      # start with a duplicate-id error.
      Supervisor.child_spec({Cachex, [name: KilnCMS.Accounts.WebAuthn.challenge_cache()]},
        id: KilnCMS.Accounts.WebAuthn.challenge_cache()
      ),
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
      # Subscribes this node to cluster-wide cache invalidations (#739), so a
      # deleted code-injection snippet stops executing everywhere rather than
      # on whichever node served the delete. After PubSub, which it needs.
      KilnCMS.Cache.ClusterBust,
      # Fire-and-forget tasks off the request hot path (best-effort page-view
      # analytics, search-query recording) so a DB write can't queue/slow
      # delivery. `max_children` bounds in-flight tasks: under a crawler/traffic
      # spike, excess best-effort writes are dropped instead of spawning without
      # limit and exhausting the DB pool (start_child returns {:error,
      # :max_children}, which callers treat as a dropped sample). Raised from 50
      # when page-view tracking gained its daily bucket (#45): each analytics
      # task made two round trips instead of one, so the same cap would have
      # halved the concurrency headroom before views start being dropped.
      #
      # Referrer attribution (#619) adds a third round trip to that same task
      # when `KILN_ANALYTICS_REFERRERS` is on — off by default, so this cap is
      # unchanged for now, but each task then lives measurably longer under
      # load and the same cap starts shedding samples sooner at a given
      # arrival rate. Revisit this number if a deployment enables the flag and
      # sees view/day-bucket undercounting increase.
      {Task.Supervisor, name: KilnCMS.TaskSupervisor, max_children: 100},
      KilnCMSWeb.Presence,
      KilnCMS.Collab.Locks,
      # Collaborative-editing CRDT prototype (KilnCMS.Collab.Crdt): one
      # DocServer per open document, registered by channel topic. Idle-cheap —
      # servers only exist while editors are attached (+ a grace period).
      {Registry, keys: :unique, name: KilnCMS.Collab.Crdt.Registry},
      # `max_children` for the same reason as the task supervisor above (#676):
      # each DocServer pins a Yex NIF document in memory and lingers ten minutes
      # past its last client, so an unbounded supervisor is an unbounded amount
      # of resident memory. One server per document being edited, and #655 made
      # the key the resolved record, so a client can no longer conjure several
      # per document by varying the topic string — this bounds how many
      # documents can be open at once, not how many ways there are to name one.
      {DynamicSupervisor,
       name: KilnCMS.Collab.Crdt.DocSupervisor,
       strategy: :one_for_one,
       max_children: KilnCMS.Collab.Crdt.max_documents()},
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

    with {:ok, pid} <-
           Supervisor.start_link(
             children ++
               subscription_batcher() ++
               embedding_children() ++ reranker_children() ++ Kiln.Plugins.children(),
             opts
           ) do
      # Needs the Repo, so it runs after the tree is up rather than alongside
      # the config-only warnings at the top of start/2.
      warn_if_multi_tenant_without_strict_host()
      {:ok, pid}
    end
  end

  # The core Oban config with plugin queues merged in (D18) — plugins declare
  # queues in code (`oban_queues/0`) instead of editing the host's config.
  defp oban_config do
    Application.fetch_env!(:kiln_cms, Oban)
    |> Keyword.update(:queues, Kiln.Plugins.oban_queues(), fn queues ->
      Keyword.merge(Kiln.Plugins.oban_queues(), queues)
    end)
    |> Keyword.update(:plugins, [], &with_cron_entries/1)
  end

  # Scheduled work, assembled here rather than written into `config :kiln_cms,
  # Oban` so a runtime override sets a flat `:kiln_cms` key. `Config`
  # deep-merges keyword lists, so overriding one entry inside a nested plugin
  # tuple from `runtime.exs` is the shape that silently deleted config in #608.
  #
  # Each entry names its config key, its worker, and the env var an operator
  # would have set — the last so a rejected expression can say which variable to
  # fix rather than "a cron expression somewhere is wrong".
  @cron_schedules [
    {:governance_checkpoint_cron, KilnCMS.Governance.CheckpointWorker,
     "KILN_GOVERNANCE_CHECKPOINT_CRON",
     "governance checkpoints will NOT be minted on a schedule. See #666."},
    {:link_check_cron, KilnCMS.Links.SweepWorker, "KILN_LINK_CHECK_CRON",
     "outbound links will NOT be checked on a schedule. See #474."},
    {:task_digest_cron, KilnCMS.Notifications.TaskDigestWorker, "KILN_TASK_DIGEST_CRON",
     "task due-soon/overdue digests will NOT be sent on a schedule. See #501."},
    {:occurrence_sweep_cron, KilnCMS.Events.SweepWorker, "KILN_OCCURRENCE_SWEEP_CRON",
     "finished events will stay at the top of the \"what's on\" index. See #766."}
  ]

  # `false` (or nil) on any key leaves that entry out, for a deployment driving
  # the work from its own scheduler.
  defp with_cron_entries(plugins) do
    case Enum.flat_map(@cron_schedules, &cron_entry/1) do
      [] -> plugins
      entries -> inject_crontab(plugins, entries)
    end
  end

  defp cron_entry({key, worker, env_var, consequence}) do
    case Application.get_env(:kiln_cms, key, false) do
      cron when is_binary(cron) ->
        case validated_cron(String.trim(cron), env_var, consequence) do
          nil -> []
          valid -> [{valid, worker}]
        end

      _disabled ->
        []
    end
  end

  defp inject_crontab(plugins, entries) do
    {plugins, injected?} =
      Enum.map_reduce(plugins, false, fn
        {Oban.Plugins.Cron, opts}, _ ->
          {{Oban.Plugins.Cron, Keyword.update(opts, :crontab, entries, &(entries ++ &1))}, true}

        plugin, injected? ->
          {plugin, injected?}
      end)

    # Silently doing nothing when the Cron plugin isn't there would stop
    # checkpoints being minted with no signal at all, which is the failure
    # mode #666 is least able to afford.
    if injected?, do: plugins, else: [{Oban.Plugins.Cron, crontab: entries} | plugins]
  end

  # The expression is VALIDATED here rather than handed to Oban raw. Oban parses
  # its crontab with a bang and raises out of `Oban.Config.new/1`, so an
  # unparseable value takes the whole supervision tree down — and the two values
  # an operator is most likely to try are exactly the ones that used to do it:
  # a blank `KILN_GOVERNANCE_CHECKPOINT_CRON=` (routine in `.env` files) and the
  # literal `false` the config comment names as the way to switch this off, which
  # arrives from the environment as the *string* `"false"`. A misconfigured
  # schedule must cost the schedule, never the boot.
  defp validated_cron("", _env_var, _consequence), do: nil

  defp validated_cron(cron, _env_var, _consequence) when cron in ~w(false off no 0), do: nil

  defp validated_cron(cron, env_var, consequence) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, _expression} ->
        cron

      {:error, _reason} ->
        IO.puts(
          :standard_error,
          "#{env_var}=#{inspect(cron)} is not a valid cron expression - " <> consequence
        )

        nil
    end
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

  # A deployment that leaves `TENANT_STRICT_HOST` off serves the DEFAULT org's
  # content, branding and analytics to any request carrying an unrecognized Host
  # (#563). That is the correct behaviour for the single-host install the
  # fallback exists for, so it can't just be flipped — but on a deployment that
  # has actually created a second org it is a live misconfig, and the operator
  # should hear it from a log line rather than from an incident.
  #
  # Boot is the WEAKEST of the three places this is checked, and deliberately
  # not the only one: it already happened by the time someone creates the second
  # org, and may not happen again for months (#660). Org creation and
  # `/editor/system` ask the same predicate — and it really is the same one,
  # rather than a second copy that drifts.
  #
  # Logger, not the stderr the config providers use, so it reaches whatever
  # ships the container's logs (#634). Note that is NOT Sentry: the
  # `Sentry.LoggerHandler` this app attaches sets no `capture_log_messages`, so
  # a plain `Logger.warning` never becomes an event.
  defp warn_if_multi_tenant_without_strict_host do
    if KilnCMSWeb.Tenant.strict_host_gap?() do
      require Logger

      Logger.warning(
        "TENANT_STRICT_HOST is off on a deployment with more than one organization. " <>
          "A request whose Host matches no org — a bare hostname, an IP, or an " <>
          "attacker-supplied header — is served the DEFAULT org's content, branding " <>
          "and analytics. Set TENANT_STRICT_HOST=true to reject those instead; see " <>
          "docs/environment-variables.md."
      )
    end
  end

  # Enabling SEO drafting against a hosted provider means page content leaves
  # the deployment. That is a legitimate operator choice, but it should never be
  # a silent one — an editor clicking "Suggest" didn't make it. Announced once
  # at boot; the editor also carries a standing notice next to the button.
  defp warn_if_seo_drafting_egresses do
    if KilnCMS.Seo.enabled?() and KilnCMS.Seo.egress?() do
      require Logger

      Logger.warning(
        "SEO drafting is enabled against #{KilnCMS.Seo.provider()} (#{KilnCMS.Seo.model()}). " <>
          "Page title, excerpt and body text are sent to that provider when an editor asks " <>
          "for suggestions. Add it to your DPA's subprocessor list, or point SEO_MODEL at a " <>
          "local endpoint (e.g. ollama:llama3.1) to keep content in the deployment."
      )
    end
  end

  # The twin warning for block assist (#60). Separate from the SEO one because
  # the switches are separate and so is what gets sent: this ships the block's
  # prose *and the author's typed instruction*, which is a different disclosure
  # to put in front of an operator.
  defp warn_if_assist_egresses do
    if KilnCMS.Assist.enabled?() and KilnCMS.Assist.egress?() do
      require Logger

      Logger.warning(
        "Block AI assist is enabled against #{KilnCMS.Assist.provider()} " <>
          "(#{KilnCMS.Assist.model()}). Block text, page context and the editor's typed " <>
          "instruction are sent to that provider on each request. Add it to your DPA's " <>
          "subprocessor list, or point ASSIST_MODEL at a local endpoint " <>
          "(e.g. ollama:llama3.1) to keep content in the deployment."
      )
    end
  end

  # The third of the trio (#339). Distinct from both above in *who* triggers
  # the egress: nobody on staff does. `/api/ask` is public and anonymous, so an
  # operator enabling this against a hosted provider is agreeing that a stranger
  # on the internet can cause published passages to be sent there.
  defp warn_if_ask_egresses do
    if KilnCMS.Ask.enabled?() and KilnCMS.Ask.egress?() do
      require Logger

      Logger.warning(
        "Ask (/api/ask) generation is enabled against #{KilnCMS.Ask.provider()} " <>
          "(#{KilnCMS.Ask.model()}). Published passages retrieved for a question are sent to " <>
          "that provider, on an endpoint any anonymous caller can reach. Add it to your DPA's " <>
          "subprocessor list, or point ASK_MODEL at a local endpoint " <>
          "(e.g. ollama:llama3.1) to keep content in the deployment."
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
