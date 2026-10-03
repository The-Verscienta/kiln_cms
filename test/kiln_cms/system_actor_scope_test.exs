defmodule KilnCMS.SystemActorScopeTest do
  @moduledoc """
  Each system-actor grant admits the subsystems its `docs/policy-matrix.md` row
  names, and **every other** subsystem is refused (#1747).

  Until #1747 `KilnCMS.Checks.SystemActor` matched any system actor, so a grant
  written for one worker was every worker's: admitting publishing to
  `Task :complete` also let the automation worker complete anyone's task. Now
  every clause names its subsystems, and this test holds the code to the
  matrix's **Subsystems** column in both directions, without a hand-written case
  per grant:

    * for every action on every resource with a grant, and every subsystem
      label the application builds an actor with
      (`KilnCMS.SystemActorGrants.all_subsystems/0`, read from the source), Ash
      is asked whether a system actor of that subsystem is admitted
      (`KilnCMS.SystemActorGrants.admitted/4`, no database needed);
    * the admitted set must equal the matrix's, exactly. A subsystem added to a
      clause, a clause's `action:` dropped, or a clause moved above a
      `forbid_unless` admits a label the row does not name; a subsystem removed
      refuses one it does. Either fails here.

  Actions the policy cannot decide without rows (the `access_type :runtime`
  reads of `Firing.PublishedArtifact`) are asked of a seeded artifact whose
  document is a draft, so no branch written for people admits it: an admitted
  subsystem must get that row back, and a refused one must not. (A runtime
  check drops the row after fetching it, so the refusal is an empty answer
  even under `authorize_with: :error`; the positive half is what keeps "no
  artifact" from passing as "refused".)
  """
  use KilnCMS.DataCase, async: true

  # Deciding a content action logs the state machine's refusal of a record
  # with no state; the decision itself is unaffected.
  @moduletag :capture_log

  alias KilnCMS.Firing
  alias KilnCMS.SystemActor
  alias KilnCMS.SystemActorGrants, as: Grants

  # Reads whose policy is `access_type :runtime`: decided against a row below.
  @data_probed %{
    Firing.PublishedArtifact => [:read, :for_document, :get_surface],
    KilnCMS.CMS.ContentLink => [:read, :backlinks, :references_from]
  }

  defp expected(resource, action),
    do: Map.get(Grants.matrix_grants(), {resource, action}, MapSet.new())

  defp list(set), do: set |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

  describe "every grant against the matrix" do
    test "each named subsystem is admitted and every other one is refused" do
      subsystems = Grants.all_subsystems()

      mismatches =
        for resource <- Grants.granting_resources(),
            {action, _type} <- Grants.actions(resource),
            action not in Map.get(@data_probed, resource, []),
            want = expected(resource, action),
            got = Grants.admitted(resource, action, subsystems),
            got == :undecidable or MapSet.new(got) != want,
            not (got == :undecidable and want == MapSet.new()) do
          case got do
            :undecidable ->
              "  * #{inspect(resource)} #{inspect(action)}: the matrix names " <>
                "#{list(want)}, but the policy cannot decide this without rows — " <>
                "add it to @data_probed with a probe against a seeded record"

            got ->
              got = MapSet.new(got)
              wide = MapSet.difference(got, want)
              narrow = MapSet.difference(want, got)

              "  * #{inspect(resource)} #{inspect(action)}:" <>
                if(wide == MapSet.new(),
                  do: "",
                  else: " admits #{list(wide)}, which its row does not name;"
                ) <>
                if(narrow == MapSet.new(),
                  do: "",
                  else: " refuses #{list(narrow)}, which its row names"
                )
          end
        end

      assert mismatches == [],
             """
             The system-actor grants and the "Subsystems" column of
             docs/policy-matrix.md ("The system actor") disagree:

             #{Enum.join(mismatches, "\n")}

             A grant admits exactly the subsystems whose code calls the action
             (see `KilnCMS.Checks.SystemActor`). If the code is right, name the
             subsystem in the matrix row, with why; if the row is right, narrow
             the clause (`subsystem:`, or `action:` when two actions in one
             clause have different callers).
             """
    end

    # Guards the guard: a table the parser no longer reads, or a universe of one
    # label, would pass the test above vacuously.
    test "the comparison actually covers the grants" do
      grants = Grants.matrix_grants()
      subsystems = Grants.all_subsystems()

      assert map_size(grants) > 150, "parsed only #{map_size(grants)} matrix grants"
      assert length(subsystems) > 30, "only #{length(subsystems)} subsystem labels found"
      assert :__no_grant_names_this__ not in subsystems

      # The labels the #1659 batches introduced are all in the universe — a
      # regex that stopped matching `system(:label)` would drop them.
      for label <- [:cms_bookkeeping, :cms_registry, :releases, :operator, :publish_gate, :feeds] do
        assert label in subsystems, "#{inspect(label)} is missing from all_subsystems/0"
      end
    end

    test "every resource and action a row names exists" do
      unknown =
        for {{resource, action}, _subsystems} <- Grants.matrix_grants(),
            not Code.ensure_loaded?(resource) or
              is_nil(Ash.Resource.Info.action(resource, action)),
            do: "#{inspect(resource)} #{inspect(action)}"

      assert unknown == [],
             "the matrix names actions that do not exist: #{Enum.join(unknown, ", ")}"
    end
  end

  describe "Firing.PublishedArtifact reads, against a row" do
    setup do
      org_id = KilnCMS.Accounts.default_org_id()

      # A draft: no branch for people admits its artifact, so only the system
      # clause can.
      draft =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Scope probe",
          slug: "scope-probe-#{System.unique_integer([:positive])}",
          locale: "en",
          state: :draft
        })

      artifact =
        Ash.Seed.seed!(Firing.PublishedArtifact, %{
          org_id: org_id,
          document_type: :page,
          document_id: draft.id,
          surface: :web,
          format_version: 1,
          body: %{"html" => "<p>draft</p>"},
          fired_at: DateTime.utc_now()
        })

      %{org_id: org_id, draft: draft, artifact: artifact}
    end

    test "each read admits the subsystems its row names, and refuses every other", ctx do
      reads = %{
        read: fn opts ->
          Firing.list_artifacts(Keyword.put(opts, :query, filter: [id: ctx.artifact.id]))
        end,
        for_document: &Firing.artifacts_for(:page, ctx.draft.id, &1),
        get_surface: &Firing.get_artifact(:page, ctx.draft.id, :web, &1)
      }

      assert Map.keys(reads) |> Enum.sort() ==
               Enum.sort(@data_probed[Firing.PublishedArtifact])

      for {action, read} <- reads, subsystem <- Grants.all_subsystems() do
        admitted? =
          case read.(
                 actor: SystemActor.new(subsystem),
                 tenant: ctx.org_id,
                 authorize_with: :error
               ) do
            {:ok, [%{id: id}]} -> id == ctx.artifact.id
            {:ok, %{id: id}} -> id == ctx.artifact.id
            {:ok, empty} when empty in [[], nil] -> false
            {:error, %Ash.Error.Forbidden{}} -> false
            {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} -> false
          end

        assert admitted? == MapSet.member?(expected(Firing.PublishedArtifact, action), subsystem),
               "PublishedArtifact #{inspect(action)} as #{inspect(subsystem)}: " <>
                 "admitted? #{admitted?}, but the matrix row says the opposite"
      end
    end
  end

  describe "CMS.ContentLink reads, against a row" do
    setup do
      org_id = KilnCMS.Accounts.default_org_id()

      # A draft at both ends: no branch for people admits the edge (an
      # anonymous reader may read neither end), so only the system clause can.
      draft = fn ->
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Link probe",
          slug: "link-probe-#{System.unique_integer([:positive])}",
          locale: "en",
          state: :draft
        })
      end

      source = draft.()
      target = draft.()

      link =
        Ash.Seed.seed!(KilnCMS.CMS.ContentLink, %{
          org_id: org_id,
          source_id: source.id,
          target_id: target.id,
          kind: :reference,
          field: "probe"
        })

      %{org_id: org_id, source: source, target: target, link: link}
    end

    test "each read admits the subsystems its row names, and refuses every other", ctx do
      reads = %{
        read: &KilnCMS.CMS.list_content_links(Keyword.put(&1, :query, filter: [id: ctx.link.id])),
        backlinks: &KilnCMS.CMS.list_backlinks(ctx.target.id, &1),
        references_from: &KilnCMS.CMS.list_reference_links(ctx.source.id, &1)
      }

      assert Map.keys(reads) |> Enum.sort() ==
               Enum.sort(@data_probed[KilnCMS.CMS.ContentLink])

      for {action, read} <- reads, subsystem <- Grants.all_subsystems() do
        admitted? =
          case read.(
                 actor: SystemActor.new(subsystem),
                 tenant: ctx.org_id,
                 authorize_with: :error
               ) do
            {:ok, [%{id: id}]} -> id == ctx.link.id
            {:ok, []} -> false
            {:error, %Ash.Error.Forbidden{}} -> false
          end

        assert admitted? == MapSet.member?(expected(KilnCMS.CMS.ContentLink, action), subsystem),
               "ContentLink #{inspect(action)} as #{inspect(subsystem)}: " <>
                 "admitted? #{admitted?}, but the matrix row says the opposite"
      end
    end
  end
end
