defmodule Showcase.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ShowcaseWeb.Telemetry,
      {Phoenix.PubSub, name: Showcase.PubSub},
      ShowcaseWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Showcase.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ShowcaseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
