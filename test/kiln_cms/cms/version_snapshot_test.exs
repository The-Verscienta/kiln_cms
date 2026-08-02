defmodule KilnCMS.CMS.VersionSnapshotTest do
  @moduledoc """
  `VersionSnapshot` reconstructs a record's full state at a PaperTrail version by
  folding `:changes_only` deltas (#467), and puts a live record into the same
  shape so a saved version can be compared against the working draft.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.VersionSnapshot

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "vs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "vs-#{System.unique_integer([:positive])}"

  defp versions(page, admin) do
    CMS.list_page_versions!(actor: admin)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  defp snapshot_at(page, version, admin) do
    {:ok, snapshot} =
      VersionSnapshot.at(KilnCMS.CMS.Page.Version, page.id, version, actor: admin)

    snapshot
  end

  test "folds changes_only deltas into the full state at a version" do
    admin = admin()

    page =
      CMS.create_page!(%{title: "One", slug: slug(), seo_title: "SEO one"}, actor: admin)

    page = CMS.update_page!(page, %{title: "Two"}, actor: admin)
    page = CMS.update_page!(page, %{seo_title: "SEO three"}, actor: admin)

    [first, second, third] = versions(page, admin)

    # The middle version changed only the title — but the snapshot at that point
    # still carries the SEO title set at creation. That fold is the whole reason
    # this module exists.
    assert %{"title" => "Two", "seo_title" => "SEO one"} = snapshot_at(page, second, admin)
    assert %{"title" => "One", "seo_title" => "SEO one"} = snapshot_at(page, first, admin)
    assert %{"title" => "Two", "seo_title" => "SEO three"} = snapshot_at(page, third, admin)
  end

  test "the snapshot at the newest version matches the live record" do
    admin = admin()

    page =
      CMS.create_page!(
        %{
          title: "Live",
          slug: slug(),
          blocks: [%{type: :heading, content: "Heading", order: 0}]
        },
        actor: admin
      )

    page = CMS.update_page!(page, %{seo_description: "Described"}, actor: admin)

    latest = page |> versions(admin) |> List.last()
    saved = snapshot_at(page, latest, admin)
    current = VersionSnapshot.current(page)

    # `current/1` is the compare view's "working draft" side. If it didn't land on
    # exactly the shape PaperTrail stores, every field would read as changed the
    # moment an editor compared a version against the draft.
    for key <- ~w(title slug blocks seo_description state locale) do
      assert Map.fetch!(saved, key) == Map.fetch!(current, key),
             "#{key} drifted: stored #{inspect(saved[key])} vs current #{inspect(current[key])}"
    end
  end

  test "current/1 omits the primary key and paper-trail-ignored attributes" do
    admin = admin()
    page = CMS.create_page!(%{title: "Shape", slug: slug()}, actor: admin)

    current = VersionSnapshot.current(page)

    refute Map.has_key?(current, "id")
    refute Map.has_key?(current, "lock_version")
    refute Map.has_key?(current, "inserted_at")
    refute Map.has_key?(current, "embedding")
    assert Map.has_key?(current, "title")
  end

  test "pair/5 folds two versions from one history read" do
    admin = admin()
    page = CMS.create_page!(%{title: "A", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "B"}, actor: admin)
    page = CMS.update_page!(page, %{title: "C"}, actor: admin)

    [first, _second, third] = versions(page, admin)

    assert {:ok, old, new} =
             VersionSnapshot.pair(KilnCMS.CMS.Page.Version, page.id, first, third, actor: admin)

    assert old["title"] == "A"
    assert new["title"] == "C"
  end

  test "pair/5 bounds the read at the later cursor whichever order it is given" do
    admin = admin()
    page = CMS.create_page!(%{title: "A", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "B"}, actor: admin)

    [first, second] = versions(page, admin)

    # Newest first: the read must still reach far enough back to fold `first`.
    assert {:ok, new, old} =
             VersionSnapshot.pair(KilnCMS.CMS.Page.Version, page.id, second, first, actor: admin)

    assert old["title"] == "A"
    assert new["title"] == "B"
  end

  test "a version belonging to another record is an error, not a plausible fold" do
    admin = admin()
    page = CMS.create_page!(%{title: "Mine", slug: slug()}, actor: admin)
    other = CMS.create_page!(%{title: "Theirs", slug: slug()}, actor: admin)
    [other_version | _] = versions(other, admin)

    assert :error =
             VersionSnapshot.at(KilnCMS.CMS.Page.Version, page.id, other_version, actor: admin)
  end

  test "folding is bounded by the cursor and rejects a version outside the history" do
    admin = admin()
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "Two"}, actor: admin)

    [first, second] = versions(page, admin)
    history = [first, second]

    assert {:ok, %{"title" => "One"}} = VersionSnapshot.fold_through(history, first)
    assert {:ok, %{"title" => "Two"}} = VersionSnapshot.fold_through(history, second)
    assert :error = VersionSnapshot.fold_through(history, %{first | id: Ash.UUID.generate()})
  end

  test "a version written in the same instant is folded in regardless of its UUID" do
    admin = admin()
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "Two"}, actor: admin)
    page = CMS.update_page!(page, %{seo_title: "Seo three"}, actor: admin)

    [first, second, third] = versions(page, admin)

    # Two versions written in one transaction share an instant. `id` is a random
    # v4 UUID, so which sorts first is a coin flip — force the *later* write to
    # carry the lower id, the arrangement a tuple cutoff gets wrong.
    instant = third.version_inserted_at
    second = %{second | version_inserted_at: instant, id: "ffffffff-0000-4000-8000-000000000001"}
    third = %{third | version_inserted_at: instant, id: "00000000-0000-4000-8000-000000000001"}
    history = Enum.sort([first, second, third], &VersionSnapshot.before?/2)

    assert {:ok, snapshot} = VersionSnapshot.fold_through(history, third)

    # Cutting on `(version_inserted_at, id)` would stop at `third` and leave the
    # title at "One" — a state the document was never in. Restoring to the newest
    # version would then silently revert a field the editor never touched.
    assert snapshot["title"] == "Two"
    assert snapshot["seo_title"] == "Seo three"
  end

  test "a non-UTF-8 binary drops one field instead of taking the snapshot down" do
    admin = admin()
    page = CMS.create_page!(%{title: "Encodable", slug: slug()}, actor: admin)

    # `Jason.encode!` raises `Protocol.UndefinedError` for a struct with no
    # encoder but `Jason.EncodeError` for an invalid binary; catching only the
    # first let one bad byte anywhere in the record kill the whole comparison.
    current = VersionSnapshot.current(%{page | seo_title: <<0xFF, 0xFE>>})

    assert current["seo_title"] == nil
    assert current["title"] == "Encodable"
  end
end
