defmodule KilnCMS.CMS.BlockIdTest do
  @moduledoc """
  Stable block ids: generated at **write** time, preserved on round-trips, and
  never invented on read (two sessions lazily generating ids for the same
  stored block would diverge — the exact instability the ids exist to fix,
  since they key each block's collab Yjs fragment).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bid-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "bid-#{System.unique_integer([:positive])}"

  defp block_ids(page_id),
    do: CMS.get_page!(page_id, authorize?: false).blocks |> Enum.map(& &1.value.id)

  test "blocks written without ids get one at write time, stable across reads" do
    page =
      CMS.create_page!(
        %{
          title: "Ids",
          slug: slug(),
          blocks: [
            %{"_type" => "heading", "text" => "One"},
            %{"_type" => "rich_text", "legacy_html" => "<p>Two</p>"}
          ]
        },
        actor: admin()
      )

    [a, b] = block_ids(page.id)
    assert is_binary(a) and is_binary(b)
    refute a == b

    # Reads never mint new ids.
    assert block_ids(page.id) == [a, b]
  end

  test "supplied ids are preserved (writable — restores/round-trips keep identity)" do
    id = Ash.UUID.generate()

    page =
      CMS.create_page!(
        %{
          title: "Kept",
          slug: slug(),
          blocks: [%{"_type" => "heading", "text" => "Keep me", "id" => id}]
        },
        actor: admin()
      )

    assert block_ids(page.id) == [id]

    # An unrelated update leaves block identity untouched.
    {:ok, _} = CMS.update_page(page, %{title: "Renamed"}, actor: admin())
    assert block_ids(page.id) == [id]
  end

  test "pre-id stored rows read as nil (stably) and gain ids on their next save" do
    # A row from before block ids existed, planted beneath Ash.
    page_id = Ash.UUID.generate()

    Repo.query!(
      """
      INSERT INTO pages (id, title, slug, state, blocks, locale, audience,
                         custom_fields, lock_version, inserted_at, updated_at)
      VALUES ($1, 'Legacy', $2, 'draft', $3, 'en', 'public', '{}', 1, now(), now())
      """,
      [
        Ecto.UUID.dump!(page_id),
        slug(),
        [%{"type" => "heading", "content" => "Old", "data" => %{"level" => 2}, "order" => 0}]
      ]
    )

    # Reads are stable — nil both times, never a random id.
    assert block_ids(page_id) == [nil]
    assert block_ids(page_id) == [nil]

    # A save that carries blocks (as every editor save does) assigns a
    # persistent id. Note a blocks-free update (e.g. title-only via the API)
    # leaves them nil — the backfill migration covers those rows.
    page = CMS.get_page!(page_id, authorize?: false)

    {:ok, _} =
      CMS.update_page(page, %{blocks: [%{"_type" => "heading", "text" => "Old"}]}, actor: admin())

    assert [id] = block_ids(page_id)
    assert is_binary(id)
    assert block_ids(page_id) == [id]
  end
end
