defmodule KilnDepFixture.SecurityCheck do
  @moduledoc """
  A security posture check shipped from a dependency (kiln_cms#2252), so the
  core's suite proves one compiled before the core, against the SDK alone, is
  discovered and run. It reports the build environment it was handed, which
  is all it needs from the core.
  """
  use Kiln.Security.Check

  @impl Kiln.Security.Check
  def id, do: "dep_fixture.build_env"

  @impl Kiln.Security.Check
  def title, do: "Dependency fixture check"

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def description, do: "Proves a plugin compiled as a dependency can add a posture check."

  @impl Kiln.Security.Check
  def run(%Kiln.Security.Check.Context{build_env: env}) do
    pass("The fixture ran on a #{env} build.", facts: %{build_env: Atom.to_string(env)})
  end
end
