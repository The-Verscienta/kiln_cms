defmodule KilnClient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/The-Verscienta/kiln_cms"

  def project do
    [
      app: :kiln_client,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Official Elixir client for the Kiln CMS delivery APIs — " <>
          "published-by-default JSON:API reads, search, and fired artifacts.",
      package: package(),
      docs: docs(),
      name: "KilnClient",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      # Req.Test's stub transport rides on Plug — tests only.
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "KilnClient", extras: ["README.md"]]
  end
end
