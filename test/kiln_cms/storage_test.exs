defmodule KilnCMS.StorageTest do
  @moduledoc false
  # async: false — these tests mutate the global Storage.Local config (root).
  use ExUnit.Case, async: false

  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_storage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    %{root: root}
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
end
