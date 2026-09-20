defmodule KilnClient.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/The-Verscienta/kiln_cms"

  def project do
    [
      app: :kiln_client,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Official Elixir client for the KilnCMS APIs — published-by-default " <>
          "JSON:API reads, writes and workflow transitions, search, fired " <>
          "artifacts, media uploads, and GraphQL.",
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
      links: %{
        "GitHub" => "#{@source_url}/tree/main/clients/elixir/kiln_client",
        "Changelog" => "#{@source_url}/blob/main/clients/elixir/kiln_client/CHANGELOG.md",
        "KilnCMS" => @source_url
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "KilnClient",
      extras: ["README.md", "CHANGELOG.md"],
      # The client lives in a subdirectory of the Kiln monorepo and is tagged
      # `kiln_client-vX.Y.Z` (see `.github/workflows/release-clients.yml`), so
      # "view source" links must point at that tag *and* that subdirectory.
      source_ref: "kiln_client-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/kiln_client-v#{@version}/clients/elixir/kiln_client/%{path}#L%{line}"
    ]
  end
end
