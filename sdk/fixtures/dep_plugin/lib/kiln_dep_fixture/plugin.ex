defmodule KilnDepFixture.Plugin do
  @moduledoc """
  The entry module of a plugin compiled as a Mix dependency (#1909): one
  block and one field type, the two contributions the core bakes into
  compile-time registries, so the suite proves both reach them from a
  dependency; and, since 1.4, plug routes (#2272), which the core bakes into
  its router the same way, a human-verification provider (#2249), which the
  core resolves at run time, and a security posture check (#2252).
  """
  use Kiln.Plugin

  @impl Kiln.Plugin
  def summary, do: "Test fixture: a plugin compiled as a Mix dependency."

  # `scripts/ci/check_plugin_dep_recompile.sh` rewrites this line (adding
  # `KilnDepFixture.Ribbon`) to prove an edit here reaches the core's block
  # registry without `mix compile --force`. Keep it on one line.
  @impl Kiln.Plugin
  def blocks, do: [KilnDepFixture.Badge]

  @impl Kiln.Plugin
  def field_types, do: [KilnDepFixture.FieldTypes.Stars]

  @impl Kiln.Plugin
  def challenge_providers, do: [KilnDepFixture.ChallengeProvider]

  @impl Kiln.Plugin
  def security_checks, do: [KilnDepFixture.SecurityCheck]

  @impl Kiln.Plugin
  def plug_routes do
    [
      {:get, "/fixture-hooks/ping", KilnDepFixture.HookPlug, :ping},
      {:post, "/fixture-hooks/echo", KilnDepFixture.HookPlug, :echo},
      {:post, "/fixture-hooks/provider/:name", KilnDepFixture.HookPlug, :echo},
      {:get, "/fixture-hooks/tenant", KilnDepFixture.HookPlug, :tenant},
      {:post, "/fixture-hooks/webhook", KilnDepFixture.HookPlug, :webhook},
      {:forward, "/fixture-forward", KilnDepFixture.FeedRouter, []}
    ]
  end
end
