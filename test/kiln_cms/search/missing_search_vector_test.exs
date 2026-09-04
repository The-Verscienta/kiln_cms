defmodule KilnCMS.Search.MissingSearchVectorTest do
  @moduledoc """
  What happens when a content type's table never got its `search_vector`
  migration (#295) — the omission nothing used to reveal but a query, because
  everything else about such a type works.

  Tagged `:table_lock` and **excluded from the normal run**: dropping a column
  takes an ACCESS EXCLUSIVE lock on `pages`, held until the sandbox transaction
  rolls back, and a *pending* one queues every other connection's query on that
  table behind it. `async: false` is not enough — a process outliving an
  earlier async test still holds its own connection, and the whole pool stalls.
  CI runs this file in its own pass (`mix test --only table_lock`), where it is
  the only thing touching the table. The drop rolls back with the sandbox
  transaction.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :table_lock

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Search

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "msv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "msv-#{System.unique_integer([:positive])}"

  setup do
    admin = admin()
    term = "zibaldone#{System.unique_integer([:positive])}"

    # Written BEFORE the column goes: the refresh trigger would fail on the
    # write, which is a different failure from the one under test.
    post = CMS.create_post!(%{title: "#{term} post", slug: slug()}, actor: admin)
    page = CMS.create_page!(%{title: "#{term} page", slug: slug()}, actor: admin)

    Repo.query!("ALTER TABLE pages DROP COLUMN search_vector")

    %{admin: admin, term: term, post: post, page: page}
  end

  test "the check names the table, and the task fails the build over it" do
    assert [%{resource: KilnCMS.CMS.Page, table: "pages", missing: missing}] =
             Enum.filter(Search.SchemaCheck.report(), &(&1.table == "pages"))

    assert :column in missing

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/cannot answer a keyword search/, fn ->
          Mix.Tasks.Kiln.Search.Check.run([])
        end
      end)

    assert output =~ ~s|add_search_vector("pages")|
  end

  test "one half-migrated type no longer takes the whole sweep down", %{
    admin: admin,
    term: term,
    post: post
  } do
    log =
      capture_log(fn ->
        results = Search.global(term, actor: admin, sections: [:pages, :posts, :media])

        # The sweep answers. Before this, the `pages` leg's `undefined_column`
        # propagated out of the section fan-out and every query on the site
        # 500'd — including the ones that had nothing to do with pages.
        assert Enum.map(results[:posts], & &1.id) == [post.id]
        assert is_list(results[:pages])
        assert is_list(results[:media])
      end)

    # Loud, in the one place it can be acted on, with the fix in the message.
    assert log =~ "no `search_vector` column"
    assert log =~ ~s|add_search_vector("pages")|
  end

  test "the type itself still answers from the legs that do work", %{
    admin: admin,
    term: term,
    page: page
  } do
    capture_log(fn ->
      # The fuzzy (trigram-on-title) leg is a fallback for a thin keyword leg,
      # so a title match survives its type losing full-text search entirely.
      assert Enum.map(Search.hybrid(KilnCMS.CMS.Page, term, actor: admin), & &1.id) == [page.id]
    end)
  end

  test "a multi-word query loses both keyword legs, and the column is logged once", %{
    admin: admin,
    term: term,
    page: page
  } do
    log =
      capture_log(fn ->
        # The any-term fallback reads `search_vector` too, and an empty AND
        # leg is exactly what admits it. Both legs sit inside one
        # containment, so the fallback neither raises past it nor reports
        # the same missing column a second time; the fuzzy title leg still
        # answers.
        results = Search.hybrid(KilnCMS.CMS.Page, "#{term} page", actor: admin)
        assert Enum.map(results, & &1.id) == [page.id]
      end)

    assert length(String.split(log, "no `search_vector` column")) == 2
  end

  test "a query fault is still a raise, not an empty result set", %{admin: admin} do
    # The containment is keyed to the missing column, not to "errors in the
    # keyword leg" — an empty list must never be how a caller learns their
    # query was broken.
    assert_raise Ash.Error.Invalid, fn ->
      Search.hybrid(KilnCMS.CMS.Post, "anything", actor: admin, filters: %{category_id: "nope"})
    end
  end
end
