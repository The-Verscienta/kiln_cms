defmodule KilnCMS.CMS.MediaItemTest do
  @moduledoc """
  The document-library gate (#481): `audience` defaults to `:public` (zero
  behavior change for existing/image media), editors always see the full
  library, and gating a document actually relocates its blob between public
  and private storage — see `KilnCMS.CMS.Changes.MigrateMediaStorage`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_media_item_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_media_item_priv_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    %{root: root, private_root: private_root}
  end

  defp editor do
    Ash.Seed.seed!(User, %{
      email: "media-item-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp reader(audiences) do
    Ash.Seed.seed!(User, %{
      email: "media-reader-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer,
      audiences: audiences
    })
  end

  defp put(key, content) do
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(src, content)
    {:ok, ^key} = KilnCMS.Storage.store(key, src)
    key
  end

  defp document!(actor, attrs \\ %{}) do
    key = KilnCMS.Storage.generate_key("doc.pdf")
    put(key, "%PDF-1.7\nfake pdf bytes")

    CMS.create_media_item!(
      Map.merge(
        %{
          filename: "doc.pdf",
          content_type: "application/pdf",
          storage_key: key,
          url: KilnCMS.Storage.url(key)
        },
        attrs
      ),
      actor: actor
    )
  end

  defp image!(actor, attrs \\ %{}) do
    key = KilnCMS.Storage.generate_key("photo.png")
    put(key, "fake png bytes")

    CMS.create_media_item!(
      Map.merge(
        %{
          filename: "photo.png",
          content_type: "image/png",
          width: 100,
          height: 100,
          storage_key: key,
          url: KilnCMS.Storage.url(key)
        },
        attrs
      ),
      actor: actor
    )
  end

  describe "audience defaults and read policy" do
    test "a new item defaults to :public — zero behavior change for existing media" do
      item = image!(editor())
      assert item.audience == :public
    end

    test "an editor sees a gated item; an unaffiliated reader without that audience doesn't" do
      admin_actor = editor()
      doc = document!(admin_actor)
      {:ok, gated} = CMS.update_media_item(doc, %{audience: :member}, actor: admin_actor)

      assert Enum.any?(CMS.list_media_items!(actor: admin_actor), &(&1.id == gated.id))

      outsider = reader([])
      refute Enum.any?(CMS.list_media_items!(actor: outsider), &(&1.id == gated.id))
      assert {:error, _} = CMS.get_media_item(gated.id, actor: outsider)

      member = reader([:member])
      assert Enum.any?(CMS.list_media_items!(actor: member), &(&1.id == gated.id))
    end

    test "a :public item stays readable by anyone, gated or not" do
      admin_actor = editor()
      pic = image!(admin_actor)
      assert {:ok, _} = CMS.get_media_item(pic.id, actor: reader([]))
    end
  end

  describe "gating restrictions (MigrateMediaStorage)" do
    test "an image cannot be gated — v1 scopes the audience gate to documents" do
      actor = editor()
      pic = image!(actor)

      assert {:error, error} = CMS.update_media_item(pic, %{audience: :member}, actor: actor)
      assert error_message(error) =~ "images"

      unchanged = CMS.get_media_item!(pic.id, actor: actor)
      assert unchanged.audience == :public
    end

    test "gating is refused outright when the configured adapter has no private storage" do
      actor = editor()
      doc = document!(actor)

      # Switch to the S3 adapter without a :private_bucket configured — the
      # test.exs baseline `KilnCMS.Storage.S3` config has a public bucket
      # only, so `private_available?/0` is false and gating must be refused
      # rather than silently falling back to the public bucket.
      original = Application.get_env(:kiln_cms, KilnCMS.Storage)
      Application.put_env(:kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3)
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage, original) end)

      assert {:error, error} = CMS.update_media_item(doc, %{audience: :member}, actor: actor)
      assert error_message(error) =~ "private storage"

      unchanged = CMS.get_media_item!(doc.id, actor: actor)
      assert unchanged.audience == :public
      assert unchanged.storage_key == doc.storage_key
    end
  end

  describe "storage relocation" do
    test "gating a document moves its blob to private storage and clears the public url", %{
      root: root,
      private_root: private_root
    } do
      actor = editor()
      doc = document!(actor)
      old_key = doc.storage_key
      assert File.exists?(Path.join(root, old_key))

      {:ok, gated} = CMS.update_media_item(doc, %{audience: :member}, actor: actor)

      assert gated.audience == :member
      assert gated.storage_key != old_key
      assert gated.url == nil
      refute File.exists?(Path.join(root, old_key))
      assert File.exists?(Path.join(private_root, gated.storage_key))
      assert File.read!(Path.join(private_root, gated.storage_key)) =~ "fake pdf bytes"
    end

    test "un-gating a document moves its blob back to public storage and restores the url", %{
      root: root,
      private_root: private_root
    } do
      actor = editor()
      doc = document!(actor)
      {:ok, gated} = CMS.update_media_item(doc, %{audience: :member}, actor: actor)
      gated_key = gated.storage_key

      {:ok, back} = CMS.update_media_item(gated, %{audience: :public}, actor: actor)

      assert back.audience == :public
      assert back.storage_key != gated_key
      assert back.url == KilnCMS.Storage.url(back.storage_key)
      refute File.exists?(Path.join(private_root, gated_key))
      assert File.exists?(Path.join(root, back.storage_key))
    end

    # A gated-to-differently-gated transition (e.g. :member -> :staff) isn't
    # exercisable here: `config :kiln_cms, :audiences` (compile-time, see
    # `KilnCMS.CMS.Audiences`) configures only `[:public, :member]` in this
    # environment, so there's no second gated audience to move to. Covered by
    # code review of `MigrateMediaStorage.migrate/1`'s `cond` instead — the
    # `from == :public` and `to == :public` branches are mutually exclusive
    # with "gated -> differently gated", which falls to the `true ->
    # changeset` (no relocation) clause.

    test "an unrelated metadata edit never touches storage" do
      actor = editor()
      doc = document!(actor)
      key = doc.storage_key

      {:ok, updated} = CMS.update_media_item(doc, %{caption: "a caption"}, actor: actor)

      assert updated.storage_key == key
      assert updated.audience == :public
    end
  end

  describe "download counter" do
    test "increment_media_downloads bumps the counter atomically" do
      actor = editor()
      doc = document!(actor)
      assert doc.download_count == 0

      {:ok, once} = CMS.increment_media_downloads(doc, authorize?: false)
      assert once.download_count == 1

      {:ok, twice} = CMS.increment_media_downloads(once, authorize?: false)
      assert twice.download_count == 2
    end

    test "an ordinary actor cannot bump the counter directly" do
      actor = editor()
      doc = document!(actor)
      assert {:error, _} = CMS.increment_media_downloads(doc, actor: actor)
    end
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end
end
