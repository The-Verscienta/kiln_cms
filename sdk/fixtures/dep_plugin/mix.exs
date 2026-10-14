defmodule KilnDepFixture.MixProject do
  @moduledoc false
  # A plugin built the way a third party ships one: its own Mix project, with
  # `kiln_plugin` as its only dependency (#1909). Two things consume it:
  #
  #   * CI's `plugin_sdk` job compiles it on its own (`mix compile
  #     --warnings-as-errors` in this directory), which proves a plugin needs
  #     nothing from the core to compile. Before the SDK existed, this was the
  #     build that failed with "module Kiln.Plugin is not loaded".
  #   * The core's mix.exs takes it as a `path:` dependency under `:test`, and
  #     config/test.exs registers `KilnDepFixture.Plugin`, so the whole suite
  #     runs with a plugin that was compiled as a dependency, before the core.
  #
  # The requirement is a real version requirement on purpose, not only a
  # path: it is what `mix kiln.plugins.doctor` checks against the SDK the core
  # bundles (the core overrides the dependency, and Mix stops checking it).
  use Mix.Project

  def project do
    [
      app: :kiln_dep_fixture,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:kiln_plugin, "~> 1.2", path: "../../kiln_plugin"}]
    ]
  end
end
