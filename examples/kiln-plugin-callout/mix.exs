defmodule KilnPluginCallout.MixProject do
  use Mix.Project

  # Example third-party KilnCMS plugin package (issue #63). It contributes one
  # block type — a "callout" — to a host KilnCMS app. In a real package this
  # would be published to Hex or pulled via git; here it lives under examples/
  # as a reference and is not compiled as part of KilnCMS itself.
  def project do
    [
      app: :kiln_plugin_callout,
      version: "1.0.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # KilnCMS provides `Kiln.Block` and `KilnCMS.Plugin`. Point this at the
      # host's KilnCMS — a Hex release, a git ref, or a local path:
      #   {:kiln_cms, "~> 0.1"}
      #   {:kiln_cms, git: "https://github.com/The-Verscienta/kiln_cms"}
      {:kiln_cms, path: "../.."}
    ]
  end
end
