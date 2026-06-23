defmodule KilnCMS.CMS.MediaArchivalTest do
  @moduledoc """
  MediaItem uses AshArchival: `destroy` soft-deletes (sets `archived_at`),
  hiding the item from the library while keeping the row and its storage blobs —
  so published content still pointing at it keeps working. `:restore` brings it
  back; `:purge` permanently removes it.
  """
  use KilnCMS.DataCase, async: true
  import Ecto.Query

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "media-arch-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp media(attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.MediaItem,
      Map.merge(
        %{filename: "x.png", url: "/uploads/#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp archived_at(id) do
    KilnCMS.Repo.one(
      from m in "media_items",
        where: m.id == ^Ecto.UUID.dump!(id),
        select: m.archived_at
    )
  end

  test "destroying soft-deletes the item and excludes it from reads" do
    admin = user(:admin)
    item = media()

    assert :ok = CMS.destroy_media_item!(item, actor: admin)

    # Hidden from the library, but the row is retained with archived_at stamped.
    assert {:error, _} = CMS.get_media_item(item.id, actor: admin)
    refute Enum.any?(CMS.list_media_items!(actor: admin), &(&1.id == item.id))
    assert archived_at(item.id)
  end

  test "trashed lists soft-deleted items and restore brings them back" do
    admin = user(:admin)
    item = media()
    assert :ok = CMS.destroy_media_item!(item, actor: admin)

    assert [trashed] = CMS.list_trashed_media_items!(actor: admin)
    assert trashed.id == item.id

    assert {:ok, _} = CMS.restore_media_item(trashed, actor: admin)
    refute archived_at(item.id)
    assert CMS.get_media_item!(item.id, actor: admin).id == item.id
  end

  test "purge permanently removes the row" do
    admin = user(:admin)
    item = media()
    assert :ok = CMS.destroy_media_item!(item, actor: admin)

    [trashed] = CMS.list_trashed_media_items!(actor: admin)
    assert :ok = CMS.purge_media_item!(trashed, actor: admin)

    assert is_nil(
             KilnCMS.Repo.one(
               from m in "media_items", where: m.id == ^Ecto.UUID.dump!(item.id), select: m.id
             )
           )
  end

  test "delete, trash, and restore are admin-only" do
    editor = user(:editor)
    admin = user(:admin)
    item = media()

    refute CMS.can_destroy_media_item?(editor, item)
    assert CMS.can_destroy_media_item?(admin, item)

    assert :ok = CMS.destroy_media_item!(item, actor: admin)

    # The trash read filters to nothing for non-admins (and admins see the item).
    assert CMS.list_trashed_media_items!(actor: editor) == []
    assert [trashed] = CMS.list_trashed_media_items!(actor: admin)

    refute CMS.can_restore_media_item?(editor, trashed)
    refute CMS.can_purge_media_item?(editor, trashed)
  end
end
