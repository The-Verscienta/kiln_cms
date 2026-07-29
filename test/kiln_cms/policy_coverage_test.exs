defmodule KilnCMS.PolicyCoverageTest do
  @moduledoc """
  Structural guard: every resource is covered by the policy authorizer (#51).

  CONTRIBUTING says "a new resource without policies is a bug", but nothing
  enforced it. The gap matters because the two failure modes are not
  symmetrical:

    * A resource that HAS `Ash.Policy.Authorizer` but no matching policy fails
      **closed** — Ash forbids when no policy matches, so a missing clause is a
      broken feature, and you find out immediately.
    * A resource that declares NO authorizer at all fails **open**. No domain
      here declares an `authorization do` block and none sets `require_actor?`,
      so there is no backstop: the resource is simply world-readable and
      world-writable through GraphQL, JSON:API, MCP and the write API.

  Nothing about the second case is loud. It looks like a working resource. This
  test is the backstop — it fails the build the moment a resource is registered
  in `:ash_domains` without policy coverage.

  Embedded resources are exempt: they have no independent read/write path and
  are authorized through the attribute on the parent resource that holds them.
  """
  use ExUnit.Case, async: true

  @domains Application.compile_env!(:kiln_cms, :ash_domains)

  # Every non-embedded resource registered across all configured domains.
  defp governed_resources do
    for domain <- @domains,
        resource <- Ash.Domain.Info.resources(domain),
        not Ash.Resource.Info.embedded?(resource),
        do: {domain, resource}
  end

  test "every registered resource declares Ash.Policy.Authorizer" do
    offenders =
      for {domain, resource} <- governed_resources(),
          Ash.Policy.Authorizer not in Ash.Resource.Info.authorizers(resource),
          do: "#{inspect(resource)} (domain #{inspect(domain)})"

    assert offenders == [],
           """
           These resources declare no policy authorizer, which means they are
           NOT authorized at all — reads and writes succeed for any actor,
           including anonymous callers:

           #{Enum.map_join(offenders, "\n", &"  * #{&1}")}

           Add to the resource:

               use Ash.Resource,
                 ...,
                 authorizers: [Ash.Policy.Authorizer]

           and a `policies do ... end` block. See docs/policy-matrix.md.
           """
  end

  test "every registered resource declares at least one policy" do
    offenders =
      for {domain, resource} <- governed_resources(),
          Ash.Policy.Info.policies(resource) == [],
          do: "#{inspect(resource)} (domain #{inspect(domain)})"

    assert offenders == [],
           """
           These resources have a policy authorizer but no policies, so every
           action on them is forbidden (Ash denies when no policy matches).
           That is fail-closed rather than dangerous, but it is never
           intentional:

           #{Enum.map_join(offenders, "\n", &"  * #{&1}")}

           Add a `policies do ... end` block and document it in
           docs/policy-matrix.md.
           """
  end

  # Guards the guard: if the domain list or the introspection API moves and
  # `governed_resources/0` starts returning nothing, both tests above would pass
  # vacuously while checking zero resources.
  test "the guard actually inspects the resource set" do
    resources = governed_resources()

    assert length(resources) > 30,
           "expected the full resource set, got #{length(resources)} — " <>
             "has :ash_domains or Ash.Domain.Info.resources/1 changed?"
  end
end
