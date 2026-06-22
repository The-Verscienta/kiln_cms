defmodule KilnCMS.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KilnCMSWeb.Telemetry,
      KilnCMSWeb.RateLimit,
      KilnCMS.Repo,
      {DNSCluster, query: Application.get_env(:kiln_cms, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:kiln_cms, :ash_domains),
         Application.fetch_env!(:kiln_cms, Oban)
       )},
      {Phoenix.PubSub, name: KilnCMS.PubSub},
      KilnCMSWeb.Presence,
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
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KilnCMSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
