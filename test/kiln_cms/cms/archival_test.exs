defmodule KilnCMS.CMS.ArchivalTest do
  @moduledoc """
  Page/Post use AshArchival: `destroy` soft-deletes (sets `archived_at`),
  excluding the record from reads while keeping the row — and, unlike a hard
  delete, it doesn't conflict with retained PaperTrail versions.
  """
  use KilnCMS.DataCase, async: true
  import Ecto.Query

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "arch-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "arch-#{System.unique_integer([:positive])}"

  test "destroying a versioned page soft-deletes it and excludes it from reads" do
    admin = admin()
    page = CMS.create_page!(%{title: "Doomed", slug: slug()}, actor: admin)
    # An extra version — a hard delete would fail the version FK; soft-delete won't.
    page = CMS.update_page!(page, %{title: "Doomed v2"}, actor: admin)

    assert :ok = CMS.destroy_page!(page, actor: admin)

    assert {:error, _} = CMS.get_page(page.id, actor: admin)
    refute Enum.any?(CMS.list_pages!(actor: admin), &(&1.id == page.id))

    # The row is retained (soft delete), with archived_at stamped.
    row =
      KilnCMS.Repo.one(
        from p in "pages",
          where: p.id == ^Ecto.UUID.dump!(page.id),
          select: %{archived_at: p.archived_at}
      )

    assert row && row.archived_at
  end

  test "destroy is still admin-only" do
    editor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "arch-ed-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    admin = admin()
    page = CMS.create_page!(%{title: "Keep", slug: slug()}, actor: admin)

    refute CMS.can_destroy_page?(editor, page)
    assert CMS.can_destroy_page?(admin, page)
  end
end
