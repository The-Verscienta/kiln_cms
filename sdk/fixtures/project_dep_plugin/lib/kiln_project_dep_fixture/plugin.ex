defmodule KilnProjectDepFixture.Plugin do
  @moduledoc """
  A plugin installed through `config/project_deps.exs` (#1967). It
  contributes nothing; what `scripts/ci/check_project_deps.sh` checks is that
  it was installed at all, and where its lock entries went.
  """
  use Kiln.Plugin

  @impl Kiln.Plugin
  def summary, do: "Test fixture: " <> Recase.to_sentence("installed_through_project_deps")
end
