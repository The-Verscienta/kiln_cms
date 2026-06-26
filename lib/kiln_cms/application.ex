defmodule KilnCMS.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KilnCMSWeb.Telemetry,
      # Reclaim stale rate-limit buckets so an IP-rotating flood can't grow the
      # ETS table without bound (one row per `bucket:IP` otherwise lives forever).
      {KilnCMSWeb.RateLimit, clean_period: :timer.minutes(1), key_older_than: :timer.minutes(5)},
      # Bounded LRW content cache (see `KilnCMS.Cache.child_spec/1`).
      KilnCMS.Cache,
      Supervisor.child_spec({Cachex, name: KilnCMS.Firing.Cache.cache_name()}, id: :firing_cache),
      KilnCMS.Repo,
      {DNSCluster, query: Application.get_env(:kiln_cms, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:kiln_cms, :ash_domains),
         Application.fetch_env!(:kiln_cms, Oban)
       )},
      {Phoenix.PubSub, name: KilnCMS.PubSub},
      KilnCMSWeb.Presence,
      KilnCMS.Collab.Locks,
      # Start a worker by calling: KilnCMS.Worker.start_link(arg)
      # {KilnCMS.Worker, arg},
      # Start to serve requests, typically the last entry
      KilnCMSWeb.Endpoint,
      {Absinthe.Subscription, KilnCMSWeb.Endpoint},
      AshGraphql.Subscription.Batcher,
      {AshAuthentication.Supervisor, [otp_app: :kiln_cms]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: KilnCMS.Supervisor]
    Supervisor.start_link(children ++ embedding_children() ++ reranker_children(), opts)
  end

  # The embedding serving is only started when semantic search is enabled with
  # the local Bumblebee adapter — loading the model is expensive, so the default
  # install (and any deployment using a remote embedder) skips it entirely.
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
