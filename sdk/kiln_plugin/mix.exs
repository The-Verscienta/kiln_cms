defmodule KilnPlugin.MixProject do
  use Mix.Project

  @version "1.2.0"
  @source_url "https://github.com/The-Verscienta/kiln_cms"

  def project do
    [
      app: :kiln_plugin,
      version: @version,
      # The same requirement as the core's own mix.exs: 1.20 is the only
      # toolchain either is built and tested on (.tool-versions), so claiming an
      # older one here would be a promise nothing checks.
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "The compile-time plugin contract for KilnCMS: Kiln.Plugin, Kiln.Block, " <>
          "Kiln.FieldType, Kiln.Forms.SpamCheck, Kiln.ImageBackend and Kiln.Advisory, " <>
          "so a plugin can ship as a Hex, git or path dependency.",
      package: package(),
      docs: docs(),
      name: "KilnPlugin",
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  # The lower bounds are the versions the core's mix.lock builds and tests the
  # contract against (ash 3.34.6, spark 2.7.6 when this package was extracted,
  # #1909). Inside a KilnCMS build the core's lock decides the exact versions;
  # these only say which ones this package has been proven with.
  defp deps do
    [
      # `use Kiln.Block` expands to `use Ash.Resource` (an embedded resource),
      # and `Kiln.Block.Dsl` is a Spark extension of it.
      {:ash, "~> 3.34"},
      {:spark, "~> 2.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "#{@source_url}/tree/main/sdk/kiln_plugin",
        "Changelog" => "#{@source_url}/blob/main/sdk/kiln_plugin/CHANGELOG.md",
        "KilnCMS" => @source_url
      },
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      # Lives in a subdirectory of the Kiln monorepo and is tagged
      # `kiln_plugin-vX.Y.Z` (see `.github/workflows/release-clients.yml`), so
      # "view source" links point at that tag *and* that subdirectory.
      source_ref: "kiln_plugin-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/kiln_plugin-v#{@version}/sdk/kiln_plugin/%{path}#L%{line}",
      groups_for_modules: [
        Plugin: [Kiln.Plugin],
        Blocks: ~r/^Kiln\.Block(\.|$)/,
        "Field types": [Kiln.FieldType, Kiln.Tokens],
        "Spam checks": ~r/^Kiln\.Forms\.SpamCheck(\.|$)/,
        "Advisory checks": ~r/^Kiln\.Advisory(\.|$)/,
        "Image backends": [Kiln.ImageBackend]
      ]
    ]
  end
end
