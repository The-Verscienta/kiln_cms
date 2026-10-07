defmodule KilnCMS.ReleaseImportTest do
  @moduledoc """
  The importers as a release runs them (`bin/kiln_cms rpc
  'KilnCMS.Release.import_wordpress(...)'`), with no Mix in the VM: output
  through `IO.puts/1`, refusals returned rather than raised, and keyword
  options in place of flags.

  The import itself is `Portability.Import`'s and tested there; the flag
  surface is the mix tasks' (`Mix.Tasks.Kiln.PortabilityTasksTest`). This pins
  what only the release path decides.
  """
  # async: false — `drain_media:` drains the whole media queue.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.GhostFixture
  alias KilnCMS.OrgFixtures
  alias KilnCMS.Release
  alias KilnCMS.WXRFixture

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "release-import-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    dir =
      Path.join(System.tmp_dir!(), "kiln-release-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{actor: actor, dir: dir}
  end

  defp write!(ctx, name, contents) do
    path = Path.join(ctx.dir, name)
    File.write!(path, contents)
    path
  end

  # The result and everything printed, the way an `rpc` terminal sees it.
  defp run(fun) do
    test = self()
    out = capture_io(fn -> send(test, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, out}
  end

  describe "import_wordpress/2" do
    test "a dry run prints the same report the task does, and writes nothing", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      {result, out} = run(fn -> Release.import_wordpress(path, dry_run: true) end)

      assert {:ok, %{dry_run: true}} = result
      assert out =~ "Read 3 importable records, 1 attachments, 1 authors"
      assert out =~ "Acting as #{ctx.actor.email} in org"
      assert out =~ "── DRY RUN — nothing was written"
      assert out =~ "Records:   3 would be created"
      assert CMS.list_posts!(actor: ctx.actor) == []
    end

    test "a real run takes the task's options as keywords, author_map as a map", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())
      org = OrgFixtures.org("release-wp")

      {result, out} =
        run(fn ->
          Release.import_wordpress(path,
            org: org.slug,
            actor: ctx.actor.email,
            skip_media: true,
            redirects: false,
            limit: 1,
            author_map: %{"jo" => ctx.actor.email}
          )
        end)

      assert {:ok, %{dry_run: false, created: [_one]}} = result
      assert out =~ "Acting as #{ctx.actor.email} in org #{org.id}"
      assert out =~ "Authors (1 mapped, 0 unmapped):"
      assert out =~ "Redirects: 0 created"
      refute out =~ "DRY RUN"
      assert [_one] = CMS.list_posts!(actor: ctx.actor, tenant: org.id)
      assert CMS.list_redirects!(actor: ctx.actor, tenant: org.id) == []
    end

    test "drain_media: runs the media queue before returning", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      {{:ok, _report}, out} =
        run(fn -> Release.import_wordpress(path, dry_run: true, drain_media: true) end)

      assert out =~ "Draining the media queue"
    end

    # The task parses `strict:`; a keyword list has no parser, so without this
    # `dry_rn: true` would be a real import.
    test "a misspelt option is refused before anything is read or written", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      {result, out} = run(fn -> Release.import_wordpress(path, dry_rn: true) end)

      assert {:error, message} = result
      assert message =~ "Unknown option(s) :dry_rn"
      assert out =~ "Unknown option(s) :dry_rn"
      refute out =~ "Read 3"
      assert CMS.list_posts!(actor: ctx.actor) == []
    end

    test "a refusal is returned and printed, not raised", ctx do
      path = Path.join(ctx.dir, "absent.xml")

      {result, out} = run(fn -> Release.import_wordpress(path) end)

      assert result == {:error, "Could not read #{path}: {:unreadable_file, :enoent}"}
      assert out =~ "Could not read #{path}: {:unreadable_file, :enoent}"
    end

    test "an unknown --actor is refused without an Acting as line", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      {result, out} = run(fn -> Release.import_wordpress(path, actor: "nobody@example.com") end)

      assert result == {:error, "No user with email nobody@example.com"}
      refute out =~ "Acting as"
    end

    test "a malformed author_map entry is refused, naming it", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      {result, _out} = run(fn -> Release.import_wordpress(path, author_map: ["jo"]) end)

      assert result == {:error, ~s(--author-map expects login=email, got: "jo")}
      assert CMS.list_posts!(actor: ctx.actor) == []
    end
  end

  describe "import_ghost/2" do
    test "site_url: resolves __GHOST_URL__, and the parser's notes are printed", ctx do
      path = write!(ctx, "ghost.json", GhostFixture.json())

      {result, out} =
        run(fn ->
          Release.import_ghost(path, site_url: "https://blog.example.com", dry_run: true)
        end)

      assert {:ok, %{dry_run: true}} = result
      assert out =~ ~r/Read \d+ importable records, \d+ feature images, \d+ authors/
      assert out =~ "Ghost version: 6.68.0"
      assert out =~ "Not as Ghost had it"
      assert out =~ "── DRY RUN — nothing was written"
    end

    test "without site_url:, the refusal shows the release form too", ctx do
      path = write!(ctx, "ghost.json", GhostFixture.json())

      {{:error, message}, _out} = run(fn -> Release.import_ghost(path) end)

      assert message =~ "writes the Ghost site's own URLs as __GHOST_URL__"
      assert message =~ ~s[KilnCMS.Release.import_ghost("#{path}", site_url: ]
    end

    test "site_url: is a Ghost option, not a WordPress one", ctx do
      path = write!(ctx, "export.xml", WXRFixture.wxr())

      assert {{:error, "Unknown option(s) :site_url" <> _}, _out} =
               run(fn -> Release.import_wordpress(path, site_url: "https://x.example") end)
    end
  end

  describe "import_content/2" do
    test "an envelope loads, with progress printed", ctx do
      envelope = %{
        "records" => [
          %{
            "type" => "post",
            "title" => "From the envelope",
            "slug" => "from-envelope",
            "locale" => "en",
            "state" => "draft",
            "blocks" => []
          }
        ]
      }

      path = write!(ctx, "content.json", Jason.encode!(envelope))

      {result, out} = run(fn -> Release.import_content(path, skip_media: true) end)

      assert {:ok, %{created: [_one]}} = result
      assert out =~ "Read 1 records from the envelope"
      assert out =~ "Records:   1 created"
      assert [%{slug: "from-envelope"}] = CMS.list_posts!(actor: ctx.actor)
    end

    test "a CSV without type: is refused", ctx do
      path = write!(ctx, "offices.csv", "title,slug\nA,a\n")

      assert {{:error, "--type is required for a CSV import"}, _out} =
               run(fn -> Release.import_content(path) end)
    end
  end

  # `bin/kiln_cms eval` starts no application: no Oban to enqueue media jobs
  # on, no SafeFetch pool, no caches. Importing there would fail halfway.
  test "on a node that is not serving, every import refuses and points at rpc", ctx do
    path = write!(ctx, "export.xml", WXRFixture.wxr())
    command = &KilnCMS.Portability.Commands.import_wordpress/3

    {result, out} = run(fn -> Release.run_import(command, path, [], false) end)

    assert {:error, message} = result
    assert message =~ "bin/kiln_cms rpc"
    assert out =~ "not `bin/kiln_cms eval`"
    refute out =~ "Read 3"
  end
end
