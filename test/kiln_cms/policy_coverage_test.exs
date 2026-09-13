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

  # ── The system actor (#1402) ──────────────────────────────────────────────
  #
  # `%KilnCMS.SystemActor{}` exists so worker/job/task code runs UNDER the
  # policies instead of around them with `authorize?: false`. That trade only
  # pays off if the grant stays visible, so both halves of "visible" are
  # enforced here rather than left to review: it is never a `bypass`, and it
  # is always written down in docs/policy-matrix.md.

  @matrix_path "docs/policy-matrix.md"

  # Every `{resource, policy}` whose checks include `Checks.SystemActor`.
  defp system_actor_policies do
    for {_domain, resource} <- governed_resources(),
        policy <- Ash.Policy.Info.policies(resource),
        Enum.any?(policy.policies, &(&1.check_module == KilnCMS.Checks.SystemActor)),
        do: {resource, policy}
  end

  # The rows of the matrix's "The system actor" table — everything between its
  # heading and the next one.
  defp matrix_system_actor_section do
    @matrix_path
    |> File.read!()
    |> String.split("### The system actor", parts: 2)
    |> case do
      [_before, after_heading] -> after_heading |> String.split("\nLegend:", parts: 2) |> hd()
      [_only] -> flunk("#{@matrix_path} has no \"### The system actor\" section")
    end
  end

  test "no resource admits the system actor through a `bypass`" do
    offenders =
      for {resource, policy} <- system_actor_policies(),
          policy.bypass?,
          do: inspect(resource)

    assert offenders == [],
           """
           These resources admit `KilnCMS.Checks.SystemActor` in a `bypass`:

           #{Enum.map_join(offenders, "\n", &"  * #{&1}")}

           A bypass short-circuits EVERY policy below it, so this is the same
           standing grant `authorize?: false` gave — including over policies a
           later PR adds beneath it, which is the thing the system actor exists
           to stop.

           Put `authorize_if KilnCMS.Checks.SystemActor` inside the policy that
           should admit system code. When a broad policy written for people
           would otherwise AND-refuse, narrow the grant inside THAT policy
           rather than reaching for a bypass:

               policy action_type([:create, :update]) do
                 authorize_if KilnCMS.CMS.Checks.EditableContentType
                 forbid_unless action([:reindex_search_text, :set_embedding])
                 authorize_if KilnCMS.Checks.SystemActor
               end

           See `KilnCMS.Checks.SystemActor` and docs/policy-matrix.md.
           """
  end

  test "every resource that admits the system actor has a row in the policy matrix" do
    section = matrix_system_actor_section()

    offenders =
      system_actor_policies()
      |> Enum.map(fn {resource, _policy} -> resource end)
      |> Enum.uniq()
      |> Enum.reject(fn resource ->
        # Rows name the resource the way the rest of the matrix does — without
        # the `KilnCMS.` prefix, in backticks.
        String.contains?(
          section,
          "`" <> String.replace_prefix(inspect(resource), "KilnCMS.", "") <> "`"
        )
      end)
      |> Enum.map(&inspect/1)

    assert offenders == [],
           """
           These resources admit `KilnCMS.Checks.SystemActor` but no row of the
           "The system actor" table in #{@matrix_path} mentions them:

           #{Enum.map_join(offenders, "\n", &"  * #{&1}")}

           The whole point of the system actor over `authorize?: false` is that
           what system code may do is written down. Add a row naming the
           resource, the actions that admit it, and why.
           """
  end

  # Guards the guard above: a renamed heading, a moved table or a check module
  # that no resource names any more would make it pass vacuously.
  test "the system-actor guard actually inspects an admission" do
    assert system_actor_policies() != [],
           "no resource admits KilnCMS.Checks.SystemActor — has the check moved?"

    assert matrix_system_actor_section() =~ "| Resource |",
           "the \"The system actor\" section of #{@matrix_path} has no table"
  end
end
