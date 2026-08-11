defmodule Mix.Tasks.Kiln.Export.StaticTest do
  @moduledoc """
  `mix kiln.export.static` (#353) — the CLI half of the static/edge export.

  The subject here is the *argument surface*, not the export itself
  (`KilnCMS.Firing.StaticExportTest` covers what lands on disk). #931: the task
  declared `org_id:`/`all_orgs:` switches and documented them with underscores,
  which `OptionParser` treats as unknown — and under `parse/2` an unknown switch
  is silently discarded, so a fleet export quietly exported one site and said it
  had succeeded.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.OrgFixtures
  alias Mix.Tasks.Kiln.Export.Static

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "static-cli-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    dir = Path.join(System.tmp_dir!(), "kiln-export-cli-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, actor: actor, default_org: KilnCMS.Accounts.default_org_id()}
  end

  # A published page in `tenant`, returning its slug. Firing happens in Oban, so
  # the caller drains ONCE after creating everything — `drain_oban/0` walks
  # every queue until a pass runs nothing, which is not worth doing per page.
  defp page(actor, tenant) do
    slug = "cli-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Exported",
          slug: slug,
          blocks: [%{type: :heading, content: "Edge", data: %{"level" => 1}, order: 0}]
        },
        actor: actor,
        tenant: tenant
      )

    CMS.publish_page!(page, actor: actor, tenant: tenant)
    slug
  end

  defp run(args), do: capture_io(fn -> Static.run(args) end)

  test "--all-orgs writes one subtree per site", ctx do
    %{dir: dir, actor: actor} = ctx
    org = OrgFixtures.org("static-cli-other")
    default_slug = page(actor, ctx.default_org)
    other_slug = page(actor, org)
    drain_oban()

    run([dir, "--all-orgs"])

    assert File.exists?(exported(dir, ctx.default_org, default_slug))
    assert File.exists?(exported(dir, org.id, other_slug))
  end

  test "--org-id exports only that site", ctx do
    %{dir: dir, actor: actor} = ctx
    org = OrgFixtures.org("static-cli-other")
    default_slug = page(actor, ctx.default_org)
    other_slug = page(actor, org)
    drain_oban()

    run([dir, "--org-id", org.id])

    assert File.exists?(Path.join([dir, "content", "page", "en", other_slug, "json.json"]))
    refute File.exists?(Path.join([dir, "content", "page", "en", default_slug, "json.json"]))
  end

  # #931 one level up from spelling: `@switches` cannot say the two org flags
  # are alternatives, so without this the fleet lands in per-org subtrees under
  # a path the operator asked to hold one site — reported as success.
  test "--org-id and --all-orgs together is an error, not a silent winner", ctx do
    assert_raise Mix.Error, ~r/alternatives/, fn ->
      run([ctx.dir, "--org-id", Ecto.UUID.generate(), "--all-orgs"])
    end
  end

  defp exported(dir, org_id, slug),
    do: Path.join([dir, org_id, "content", "page", "en", slug, "json.json"])

  # The #931 regression itself. `--all_orgs` *looks* right and is what the
  # moduledoc used to show, but OptionParser normalizes hyphens to underscores
  # in one direction only, so it is an unknown switch. Under `parse/2` it was
  # discarded and the default org was exported with a success message; under
  # `parse!/2` the operator hears about it.
  test "an underscored --all_orgs raises rather than exporting the default org", %{dir: dir} do
    assert_raise OptionParser.ParseError, ~r/all_orgs/, fn ->
      run([dir, "--all_orgs"])
    end
  end

  test "an underscored --org_id raises rather than exporting the default org", %{dir: dir} do
    assert_raise OptionParser.ParseError, ~r/org_id/, fn ->
      run([dir, "--org_id", Ecto.UUID.generate()])
    end
  end

  test "the usage error names both org flags", %{dir: _dir} do
    assert_raise Mix.Error, ~r/--all-orgs/, fn -> run([]) end
  end
end
