defmodule Mix.Tasks.Kiln.PortabilityTasksTest do
  @moduledoc """
  `mix kiln.export.content`, `mix kiln.import.content` and
  `mix kiln.import.wordpress` (#487) — the argument surface and the refusals.

  What lands in the database is `Portability.Import`/`Export`'s business and
  tested there. The subject here is what only the tasks decide: which switches
  exist (#931 found two documented ones that `parse!/2` rejected), which inputs
  are refused before anything is written, and that the export a task writes is
  one the import task reads back.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.OrgFixtures
  alias KilnCMS.WXRFixture
  alias Mix.Tasks.Kiln.Export.Content, as: ExportContent
  alias Mix.Tasks.Kiln.Import.Content, as: ImportContent
  alias Mix.Tasks.Kiln.Import.Wordpress, as: ImportWordpress

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "portability-cli-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    dir = Path.join(System.tmp_dir!(), "kiln-portability-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{actor: actor, dir: dir}
  end

  defp write!(ctx, name, contents) do
    path = Path.join(ctx.dir, name)
    File.write!(path, contents)
    path
  end

  defp output do
    collect([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  defp post!(actor, slug) do
    CMS.create_post!(
      %{
        title: "Portable #{slug}",
        slug: slug,
        block_tree: [%{"_type" => "heading", "text" => "Body", "level" => 2}]
      },
      actor: actor
    )
  end

  describe "kiln.export.content → kiln.import.content" do
    test "a JSON export written with --out loads into another organization", ctx do
      post!(ctx.actor, "round-trip")
      out = Path.join(ctx.dir, "posts.json")

      ExportContent.run(["--type", "post", "--out", out, "--actor", ctx.actor.email])

      assert output() =~ ~r/Wrote \d+ bytes to #{Regex.escape(out)}/
      assert %{"records" => [%{"slug" => "round-trip"}]} = out |> File.read!() |> Jason.decode!()

      org = OrgFixtures.org("portability-target")
      ImportContent.run([out, "--org", org.slug, "--actor", ctx.actor.email, "--skip-media"])

      out = output()
      assert out =~ "Read 1 records from the envelope"
      assert out =~ "Acting as #{ctx.actor.email} in org #{org.id}"
      assert out =~ "Records:   1 created"

      assert [%{slug: "round-trip"}] = CMS.list_posts!(actor: ctx.actor, tenant: org.id)
    end

    test "with no --out the envelope goes to stdout, and --state narrows it", ctx do
      post!(ctx.actor, "drafted")

      json =
        capture_io(fn -> ExportContent.run(["--type", "post", "--state", "published"]) end)

      assert %{"records" => []} = Jason.decode!(json)

      json = capture_io(fn -> ExportContent.run(["--type", "post", "--state", "draft"]) end)
      assert %{"records" => [%{"slug" => "drafted"}]} = Jason.decode!(json)
    end

    test "a dry-run import writes nothing and says so", ctx do
      post!(ctx.actor, "planned")
      out = Path.join(ctx.dir, "posts.json")
      ExportContent.run(["--type", "post", "--out", out])
      org = OrgFixtures.org("portability-dry")

      ImportContent.run([out, "--org", org.slug, "--dry-run", "--skip-media"])

      assert output() =~ "DRY RUN — nothing was written"
      assert CMS.list_posts!(actor: ctx.actor, tenant: org.id) == []
    end
  end

  describe "kiln.export.content refusals" do
    test "an unknown --format is refused by name" do
      assert_raise Mix.Error, ~s[unknown --format "xml" (expected json or csv)], fn ->
        ExportContent.run(["--format", "xml"])
      end
    end

    # A typo'd state used to be `String.to_existing_atom/1`'d: an ArgumentError
    # for most words, and for any word that was an atom elsewhere, an export
    # of zero records that exited 0 — an empty backup that looked like success.
    test "an unknown --state is refused by name, even one that is an atom elsewhere", ctx do
      post!(ctx.actor, "kept")

      for state <- ["publishd", "admin", "Draft"] do
        assert_raise Mix.Error,
                     ~r/unknown --state "#{state}" \(expected one of: draft, in_review, published, archived\)/,
                     fn ->
                       ExportContent.run(["--type", "post", "--state", state])
                     end
      end
    end

    test "--state in_review exports what is waiting for review", ctx do
      _draft = post!(ctx.actor, "still-draft")

      ctx.actor
      |> post!("in-review")
      |> Ash.Changeset.for_update(:submit_for_review, %{}, actor: ctx.actor)
      |> Ash.update!()

      json = capture_io(fn -> ExportContent.run(["--type", "post", "--state", "in_review"]) end)
      assert %{"records" => [%{"slug" => "in-review"}]} = Jason.decode!(json)
    end

    test "CSV needs exactly one --type: none, or two, is refused" do
      for types <- [[], ["--type", "post", "--type", "page"]] do
        assert_raise Mix.Error, ~r/--format csv needs exactly one --type/, fn ->
          ExportContent.run(["--format", "csv" | types])
        end
      end
    end

    test "CSV of a type whose records carry prose is refused, naming them", ctx do
      post!(ctx.actor, "prose-body")

      error =
        assert_raise Mix.Error, fn ->
          ExportContent.run(["--format", "csv", "--type", "post"])
        end

      assert error.message =~ "1 record(s) of post carry a block body"
      assert error.message =~ "prose-body"
      assert error.message =~ "Use --format json"
    end
  end

  describe "CSV through both tasks" do
    # Type definitions are per organization, so a target org needs its own copy
    # of the type before a CSV of it can land there.
    defp define_type!(name, actor, tenant) do
      definition =
        CMS.create_type_definition!(%{name: name, label: "Portable"},
          actor: actor,
          tenant: tenant
        )

      CMS.create_field_definition!(
        %{type_definition_id: definition.id, name: "city", label: "City", field_type: :string},
        actor: actor,
        tenant: tenant
      )
    end

    setup ctx do
      name = "portable#{System.unique_integer([:positive])}"
      define_type!(name, ctx.actor, KilnCMS.Accounts.default_org_id())
      %{name: name}
    end

    test "a flat type exports to CSV and imports back with --type", ctx do
      ContentTypes.create!(
        ctx.name,
        %{title: "Leeds office", slug: "leeds", blocks: [], custom_fields: %{"city" => "Leeds"}},
        actor: ctx.actor
      )

      out = Path.join(ctx.dir, "offices.csv")
      ExportContent.run(["--format", "csv", "--type", ctx.name, "--out", out])
      assert File.read!(out) =~ "leeds"

      org = OrgFixtures.org("portability-csv")
      define_type!(ctx.name, ctx.actor, org.id)
      ImportContent.run([out, "--type", ctx.name, "--org", org.slug])

      assert output() =~ "Records:   1 created"

      assert [%{slug: "leeds", custom_fields: %{"city" => "Leeds"}}] =
               ContentTypes.list!(ctx.name, actor: ctx.actor, tenant: org.id)
    end

    test "a CSV import without --type is refused before the file is read", ctx do
      path = write!(ctx, "offices.csv", "title,slug\nA,a\n")

      assert_raise Mix.Error, "--type is required for a CSV import", fn ->
        ImportContent.run([path])
      end
    end

    test "a CSV with a column the type does not define is refused, naming it", ctx do
      path = write!(ctx, "offices.csv", "title,slug,locale,state,cty\nA,a,en,draft,Leeds\n")

      error = assert_raise Mix.Error, fn -> ImportContent.run([path, "--type", ctx.name]) end
      assert error.message =~ "has columns this type does not define: cty"
    end

    test "an empty CSV is refused rather than importing nothing quietly", ctx do
      path = write!(ctx, "empty.csv", "")

      assert_raise Mix.Error, "#{path} has no rows", fn ->
        ImportContent.run([path, "--type", ctx.name])
      end
    end
  end

  describe "kiln.import.content refusals" do
    test "no path prints the usage" do
      assert_raise Mix.Error, ~r/Usage: mix kiln.import.content/, fn -> ImportContent.run([]) end
    end

    test "a file that is not JSON is refused as such", ctx do
      path = write!(ctx, "broken.json", "{not json")

      assert_raise Mix.Error, ~r/broken\.json is not valid JSON/, fn ->
        ImportContent.run([path])
      end
    end

    test "a missing file is refused with the read error", ctx do
      path = Path.join(ctx.dir, "absent.json")

      assert_raise Mix.Error, "Could not read #{path}: :enoent", fn ->
        ImportContent.run([path])
      end
    end

    test "JSON that is not an export envelope is refused", ctx do
      path = write!(ctx, "other.json", ~s({"posts": []}))

      assert_raise Mix.Error, ~s(That file has no "records" array), fn ->
        ImportContent.run([path])
      end
    end
  end

  describe "kiln.import.wordpress" do
    test "a dry run reads the file, writes nothing, and says so", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      ImportWordpress.run([path, "--dry-run"])
      out = output()

      assert out =~ "Read 3 importable records, 1 attachments, 1 authors"
      assert out =~ "Source site:"
      assert out =~ "DRY RUN — nothing was written"
      assert CMS.list_posts!(actor: ctx.actor) == []
    end

    test "a real run applies --author-map, --limit and --no-redirects", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      ImportWordpress.run([
        path,
        "--skip-media",
        "--no-redirects",
        "--limit",
        "1",
        "--author-map",
        "jo=#{ctx.actor.email}"
      ])

      out = output()
      assert out =~ "Records:   1 created"
      assert out =~ "Redirects: 0 created"
      assert out =~ "Authors (1 mapped, 0 unmapped):"
      assert CMS.list_redirects!(actor: ctx.actor) == []
    end

    # #931: documented but undeclared, so `parse!/2` rejected it outright.
    test "--drain-media is a declared switch and drains the queue", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      ImportWordpress.run([path, "--dry-run", "--drain-media"])

      assert output() =~ "Draining the media queue"
    end

    test "a malformed --author-map is refused before anything is imported", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      assert_raise Mix.Error, ~r/--author-map expects login=email/, fn ->
        ImportWordpress.run([path, "--skip-media", "--author-map", "jo"])
      end

      assert CMS.list_posts!(actor: ctx.actor) == []
    end

    test "no path prints the usage" do
      assert_raise Mix.Error, ~r/Usage: mix kiln.import.wordpress/, fn ->
        ImportWordpress.run([])
      end
    end

    test "a missing file is refused with the read error", ctx do
      path = Path.join(ctx.dir, "absent.xml")

      assert_raise Mix.Error, ~r/Could not read #{Regex.escape(path)}/, fn ->
        ImportWordpress.run([path])
      end
    end

    test "a file over the parser's ceiling is refused with the split-export advice", ctx do
      # Sparse: the size check is a stat, so no 64 MB is actually written.
      path = Path.join(ctx.dir, "huge.xml")
      {:ok, io} = :file.open(path, [:write, :raw])
      {:ok, _} = :file.position(io, 64 * 1024 * 1024 + 1)
      :ok = :file.write(io, "x")
      :ok = :file.close(io)

      error = assert_raise Mix.Error, fn -> ImportWordpress.run([path]) end
      assert error.message =~ "the parser's ceiling is 64 MB"
      assert error.message =~ "re-running is safe"
    end
  end
end
