defmodule KilnCMS.CMS.BlockBackfillTest do
  @moduledoc """
  The #1537 backfill against the database: rows written in the legacy shape
  (planted with a raw UPDATE, the way a pre-flip row sits at rest) come out in
  the typed shape — on pages, posts, dynamic entries and working copies — while
  what reads them sees no difference, nothing an editor would notice moves
  (`updated_at`, `lock_version`, version history), and a row it cannot convert
  is reported and left exactly as it was.

  Every assertion about "the row" re-reads the column with a raw query. A read
  through Ash would convert a legacy row on the way out and could not tell a
  rewritten row from an untouched one — which is also why the backfill itself
  cannot write through an action (see the moduledoc).

  Not async: a dynamic type goes through the per-org type registry.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.BlockBackfill
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.LegacyBlockCorpus
  alias KilnCMS.Repo

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "backfill-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "backfill-#{System.unique_integer([:positive])}"

  defp corpus(name) do
    Enum.find_value(LegacyBlockCorpus.entries(), fn
      {^name, _expectation, stored} -> stored
      _other -> nil
    end) || raise "no corpus entry #{inspect(name)}"
  end

  defp plant(table, id, column, stored) do
    {1, _} =
      Repo.update_all(
        from(r in table, where: r.id == type(^id, Ecto.UUID)),
        set: [{column, stored}]
      )

    :ok
  end

  defp stored(table, id, column) do
    Repo.one!(from(r in table, where: r.id == type(^id, Ecto.UUID), select: field(r, ^column)))
  end

  defp row(table, id) do
    Repo.one!(
      from(r in table,
        where: r.id == type(^id, Ecto.UUID),
        select: %{updated_at: r.updated_at, lock_version: r.lock_version}
      )
    )
  end

  defp envelope?(%{"type" => type, "value" => %{"_type" => type}} = element),
    do: map_size(element) == 2

  defp envelope?(_element), do: false

  defp html(record_blocks) do
    record_blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> Enum.map(&IO.iodata_to_binary(KilnCMS.Blocks.render(&1, :web) || ""))
  end

  defp reports_for(reports, table, column),
    do: Enum.find(reports, &(&1.table == table and &1.column == column))

  setup do
    actor = admin()
    org = KilnCMS.OrgFixtures.org("backfill")
    %{actor: actor, org: org}
  end

  test "legacy rows on every content table come out typed; reads see no difference", %{
    actor: actor,
    org: org
  } do
    page =
      CMS.create_page!(%{title: "Page", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    post =
      CMS.create_post!(%{title: "Post", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    name = "gadget#{System.unique_integer([:positive])}"
    CMS.create_type_definition!(%{name: name, label: "Gadget"}, actor: actor, tenant: org.id)

    entry =
      ContentTypes.create!(name, %{title: "Entry", slug: slug(), blocks: []},
        actor: actor,
        tenant: org.id
      )

    plant("pages", page.id, :blocks, corpus("seeded welcome page"))
    plant("pages", page.id, :working_blocks, corpus("image, quote, embed, divider"))
    plant("posts", post.id, :blocks, corpus("legacy columns with legacy and typed children"))

    plant(
      "entries",
      entry.id,
      :blocks,
      corpus("tiptap prose: marks, links, lists, quote, code, rule, table")
    )

    before = %{
      page: CMS.get_page!(page.id, authorize?: false, tenant: org.id),
      post: CMS.get_post!(post.id, authorize?: false, tenant: org.id),
      page_row: row("pages", page.id),
      versions: length(CMS.list_page_versions!(authorize?: false, tenant: org.id))
    }

    reports = BlockBackfill.run()

    for {table, id, column} <- [
          {"pages", page.id, :blocks},
          {"pages", page.id, :working_blocks},
          {"posts", post.id, :blocks},
          {"entries", entry.id, :blocks}
        ] do
      stored = stored(table, id, column)

      assert stored != [] and Enum.all?(stored, &envelope?/1),
             "#{table}.#{column}: #{inspect(stored)}"
    end

    assert reports_for(reports, "pages", "blocks").rewritten >= 1
    assert reports_for(reports, "pages", "working_blocks").rewritten >= 1
    assert reports_for(reports, "entries", "blocks").rewritten >= 1

    after_page = CMS.get_page!(page.id, authorize?: false, tenant: org.id)
    after_post = CMS.get_post!(post.id, authorize?: false, tenant: org.id)

    # The heading renders identically; the rich text went legacy_html → body.
    assert hd(html(after_page.blocks)) == hd(html(before.page.blocks))
    assert html(after_page.working_blocks) == html(before.page.working_blocks)
    assert html(after_post.blocks) == html(before.post.blocks)

    assert [
             _heading,
             %Ash.Union{value: %KilnCMS.Blocks.RichText{legacy_html: nil, body: [_ | _]}}
           ] =
             after_page.blocks

    # A storage rewrite, not an edit: nothing an editor or a feed reads moves.
    assert row("pages", page.id) == before.page_row
    assert length(CMS.list_page_versions!(authorize?: false, tenant: org.id)) == before.versions

    # And it is done: a second pass reads everything and writes nothing.
    again = BlockBackfill.run()
    assert Enum.sum_by(again, & &1.rewritten) == 0
    assert Enum.sum_by(again, & &1.conflicts) == 0
  end

  test "a row it cannot convert is reported and left byte-for-byte as it was", %{
    actor: actor,
    org: org
  } do
    page =
      CMS.create_page!(%{title: "Lossy", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    lossy = corpus("legacy data the typed block has nowhere to keep")
    plant("pages", page.id, :blocks, lossy)
    stored_before = stored("pages", page.id, :blocks)

    assert {:error, message} =
             BlockBackfill.run_and_report([tables: ["pages"]], &send(self(), {:line, &1}))

    assert message =~ "1 row(s) could not be converted"

    assert stored("pages", page.id, :blocks) == stored_before

    lines = collect_lines()
    assert Enum.any?(lines, &(&1 =~ "unconvertible: pages.blocks id=#{page.id}"))
    assert Enum.any?(lines, &(&1 =~ "blocks[1] lossy (data.width)"))
  end

  test "a block kept in legacy_html is flagged, and the rest of its row still converts", %{
    actor: actor,
    org: org
  } do
    page =
      CMS.create_page!(%{title: "Kept", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    plant(
      "pages",
      page.id,
      :blocks,
      corpus("prose next to a code block with marks Portable Text code cannot hold")
    )

    assert {:error, _message} =
             BlockBackfill.run_and_report([tables: ["pages"]], &send(self(), {:line, &1}))

    assert [heading, rich_text] = stored("pages", page.id, :blocks)
    assert envelope?(heading) and envelope?(rich_text)
    assert rich_text["value"]["legacy_html"] =~ "<strong>bold</strong>"

    assert Enum.any?(
             collect_lines(),
             &(&1 =~ "needs a look: pages.blocks id=#{page.id}" and &1 =~ "legacy_html_kept")
           )
  end

  test "a dry run classifies and writes nothing", %{actor: actor, org: org} do
    page =
      CMS.create_page!(%{title: "Dry", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    legacy = corpus("seeded welcome page")
    plant("pages", page.id, :blocks, legacy)
    stored_before = stored("pages", page.id, :blocks)

    reports = BlockBackfill.run(dry_run: true, tables: ["pages"])

    assert reports_for(reports, "pages", "blocks").rewritten >= 1
    assert stored("pages", page.id, :blocks) == stored_before
  end

  test "paging carries on past the first batch", %{actor: actor, org: org} do
    ids =
      for _ <- 1..5 do
        page =
          CMS.create_page!(%{title: "Batch", slug: slug(), blocks: []},
            actor: actor,
            tenant: org.id
          )

        plant("pages", page.id, :blocks, corpus("heading levels as the form posted them"))
        page.id
      end

    BlockBackfill.run(batch: 2, tables: ["pages"])

    for id <- ids, do: assert(Enum.all?(stored("pages", id, :blocks), &envelope?/1))
  end

  test "mix kiln.blocks.backfill prints the report and fails on an unconvertible row", %{
    actor: actor,
    org: org
  } do
    page =
      CMS.create_page!(%{title: "Task", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    plant("pages", page.id, :blocks, corpus("a block from a plugin that is gone"))

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    assert_raise Mix.Error, ~r/could not be converted/, fn ->
      Mix.Tasks.Kiln.Blocks.Backfill.run(["--dry-run", "--table", "pages"])
    end

    assert_received {:mix_shell, :info, [summary]}
    assert summary =~ "pages.blocks:"
    assert_received {:mix_shell, :info, [line]}
    assert line =~ "id=#{page.id}" and line =~ "unknown_type"
  end

  # The write is a compare-and-swap: an editor who saved between the pass's
  # read and its write keeps their save.
  test "a row saved underneath the pass is not overwritten", %{actor: actor, org: org} do
    page =
      CMS.create_page!(%{title: "Race", slug: slug(), blocks: []}, actor: actor, tenant: org.id)

    plant("pages", page.id, :blocks, corpus("seeded welcome page"))
    read_by_the_pass = stored("pages", page.id, :blocks)
    {:rewrite, rewritten, _notes} = BlockBackfill.convert(read_by_the_pass)

    CMS.update_page!(page, %{blocks: [%{"_type" => "heading", "text" => "Saved meanwhile"}]},
      actor: actor,
      tenant: org.id
    )

    saved = stored("pages", page.id, :blocks)
    target = Enum.find(BlockBackfill.targets(), &(&1.table == "pages"))

    refute BlockBackfill.write(Repo, target, page.id, :blocks, read_by_the_pass, rewritten)
    assert stored("pages", page.id, :blocks) == saved

    # …and against what is actually there, it does write.
    assert BlockBackfill.write(Repo, target, page.id, :blocks, saved, rewritten)
  end

  test "targets every table with a block tree, overlay and dynamic types included" do
    tables = Enum.map(BlockBackfill.targets(), &{&1.table, &1.columns})

    assert {"pages", [:blocks, :working_blocks]} in tables
    assert {"posts", [:blocks, :working_blocks]} in tables
    assert {"entries", [:blocks, :working_blocks]} in tables
  end

  defp collect_lines(acc \\ []) do
    receive do
      {:line, line} -> collect_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
