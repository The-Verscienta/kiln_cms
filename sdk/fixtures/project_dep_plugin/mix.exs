defmodule KilnProjectDepFixture.MixProject do
  @moduledoc false
  # A plugin installed the way a site installs one (#1967): through the
  # overlay's git-ignored `config/project_deps.exs`, never through the core's
  # mix.exs. Only `scripts/ci/check_project_deps.sh` installs it, so the core
  # never sees it otherwise; `sdk/fixtures/dep_plugin` is the fixture the suite
  # runs with, and it can't serve here because the core's mix.exs already
  # declares it, so the check would pass with the hook removed.
  #
  # `recase` is here for the lock: a `path:` dependency has no lock entry, so
  # without a Hex dependency of its own the check could not show that the new
  # entry lands in `config/project.lock` and `mix.lock` stays untouched. Any
  # small package the core doesn't use would do.
  use Mix.Project

  def project do
    [
      app: :kiln_project_dep_fixture,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [
        {:kiln_plugin, "~> 1.0", path: "../../kiln_plugin"},
        {:recase, "~> 0.8"}
      ]
    ]
  end
end
