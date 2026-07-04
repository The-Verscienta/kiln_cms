defmodule Showcase.MixProject do
  use Mix.Project

  def project do
    [
      app: :showcase,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # A headless consumer — no Ecto, no database. The app talks to KilnCMS purely
  # over HTTP (Req) and renders the responses with Phoenix LiveView.
  def application do
    [
      mod: {Showcase.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild showcase"],
      "assets.deploy": ["esbuild showcase --minify"]
    ]
  end
end
