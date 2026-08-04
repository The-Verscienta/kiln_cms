defmodule KilnCMS.StorageTest do
  @moduledoc false
  # async: false — these tests mutate the global Storage.Local config (root).
  use ExUnit.Case, async: false

  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_storage_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_storage_priv_#{System.unique_integer([:positive])}")

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

  defp tmp_source(contents) do
    path = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  test "generate_key keeps the lowercased extension and is unique" do
    key = Storage.generate_key("Photo.JPG")
    assert String.ends_with?(key, ".jpg")
    assert Storage.generate_key("Photo.JPG") != Storage.generate_key("Photo.JPG")
  end

  test "store writes the file and url points at it", %{root: root} do
    src = tmp_source("hello")
    key = Storage.generate_key("a.txt")

    assert {:ok, ^key} = Storage.store(key, src)
    assert File.read!(Path.join(root, key)) == "hello"
    assert Storage.url(key) == "/uploads/#{key}"
  end

  test "store rejects keys that would escape the storage root" do
    src = tmp_source("x")
    assert {:error, :invalid_key} = Storage.store("../escape.txt", src)
    assert {:error, :invalid_key} = Storage.store("sub/dir.txt", src)
  end

  test "fetch reads the stored bytes back, and errors for a missing/unsafe key" do
    key = Storage.generate_key("c.txt")
    {:ok, _} = Storage.store(key, tmp_source("the-bytes"))

    assert {:ok, "the-bytes"} = Storage.fetch(key)
    assert {:error, :enoent} = Storage.fetch(Storage.generate_key("missing.txt"))
    assert {:error, :invalid_key} = Storage.fetch("../escape.txt")
  end

  test "delete removes the file and is idempotent", %{root: root} do
    src = tmp_source("x")
    key = Storage.generate_key("b.txt")
    {:ok, _} = Storage.store(key, src)
    assert File.exists?(Path.join(root, key))

    assert :ok = Storage.delete(key)
    refute File.exists?(Path.join(root, key))
    # Deleting a missing blob is still :ok.
    assert :ok = Storage.delete(key)
  end

  describe "private storage (#481)" do
    test "the Local adapter is always available", %{} do
      assert Storage.private_available?() == true
    end

    test "store_private writes under the SEPARATE private root, not the public one", %{
      root: root,
      private_root: private_root
    } do
      src = tmp_source("secret")
      key = Storage.generate_key("doc.pdf")

      assert {:ok, ^key} = Storage.store_private(key, src)
      assert File.read!(Path.join(private_root, key)) == "secret"
      refute File.exists?(Path.join(root, key))
    end

    test "fetch_private reads the stored bytes back, and errors for a missing/unsafe key" do
      key = Storage.generate_key("doc.pdf")
      {:ok, _} = Storage.store_private(key, tmp_source("private-bytes"))

      assert {:ok, "private-bytes"} = Storage.fetch_private(key)
      assert {:error, :enoent} = Storage.fetch_private(Storage.generate_key("missing.pdf"))
      assert {:error, :invalid_key} = Storage.fetch_private("../escape.pdf")
    end

    test "a public fetch can't read a private blob, and vice versa" do
      key = Storage.generate_key("doc.pdf")
      {:ok, _} = Storage.store_private(key, tmp_source("private-bytes"))

      assert {:error, :enoent} = Storage.fetch(key)
    end

    test "delete_private removes the file and is idempotent", %{private_root: private_root} do
      src = tmp_source("x")
      key = Storage.generate_key("doc.pdf")
      {:ok, _} = Storage.store_private(key, src)
      assert File.exists?(Path.join(private_root, key))

      assert :ok = Storage.delete_private(key)
      refute File.exists?(Path.join(private_root, key))
      assert :ok = Storage.delete_private(key)
    end
  end
end
