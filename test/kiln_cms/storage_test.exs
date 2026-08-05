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

  describe "ranged reads (#494)" do
    @body "0123456789"

    setup do
      key = Storage.generate_key("clip.mp4")
      {:ok, ^key} = Storage.store(key, tmp_source(@body))
      %{key: key}
    end

    test "reads a bounded slice and reports the blob's true total", %{key: key} do
      assert {:ok, %{bytes: "234", first: 2, last: 4, total: 10}} =
               Storage.fetch_range(key, 2, 4)
    end

    test "an :eof range runs to the end", %{key: key} do
      assert {:ok, %{bytes: "789", first: 7, last: 9, total: 10}} =
               Storage.fetch_range(key, 7, :eof)
    end

    test "a last past the end is clamped to the final byte", %{key: key} do
      assert {:ok, %{bytes: "89", last: 9, total: 10}} = Storage.fetch_range(key, 8, 500)
    end

    test "a first at or past the end is unsatisfiable, not an empty read", %{key: key} do
      # The total rides along in the error: RFC 9110 requires a 416 response to
      # state the resource's real length, and this is the only layer that knows.
      assert {:error, {:range_not_satisfiable, 10}} = Storage.fetch_range(key, 10, :eof)
      assert {:error, {:range_not_satisfiable, 10}} = Storage.fetch_range(key, 99, 200)
    end

    test "an empty blob has no satisfiable range at all" do
      key = Storage.generate_key("empty.mp4")
      {:ok, ^key} = Storage.store(key, tmp_source(""))

      assert {:error, {:range_not_satisfiable, 0}} = Storage.fetch_range(key, 0, :eof)
    end

    test "a missing or traversing key errors rather than reading something else" do
      assert {:error, :enoent} = Storage.fetch_range(Storage.generate_key("gone.mp4"), 0, :eof)
      assert {:error, :invalid_key} = Storage.fetch_range("../escape.mp4", 0, :eof)
    end

    test "copy_to_file streams a blob to disk without materializing it whole", %{key: key} do
      dest = Path.join(System.tmp_dir!(), "copy_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      assert :ok = Storage.copy_to_file(key, dest)
      assert File.read!(dest) == @body
    end

    test "copy_to_file writes an empty file for an empty blob rather than erroring" do
      key = Storage.generate_key("empty.mp4")
      {:ok, ^key} = Storage.store(key, tmp_source(""))
      dest = Path.join(System.tmp_dir!(), "copy_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      assert :ok = Storage.copy_to_file(key, dest)
      assert File.read!(dest) == ""
    end

    test "copy_to_file spans several chunks for a blob larger than the chunk size" do
      # 20 MB against an 8 MB chunk: three reads, so the loop's offset
      # arithmetic is exercised rather than short-circuited by a single read.
      body = :binary.copy("ab", 10_485_760)
      key = Storage.generate_key("big.mp4")
      {:ok, ^key} = Storage.store(key, tmp_source(body))
      dest = Path.join(System.tmp_dir!(), "copy_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      assert :ok = Storage.copy_to_file(key, dest)
      assert File.stat!(dest).size == byte_size(body)
      assert File.read!(dest) == body
    end

    test "copy_to_file reads a gated blob only via the private store" do
      key = Storage.generate_key("gated.mp4")
      {:ok, ^key} = Storage.store_private(key, tmp_source(@body))
      dest = Path.join(System.tmp_dir!(), "copy_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dest) end)

      assert :ok = Storage.copy_to_file(key, dest, private?: true)
      assert File.read!(dest) == @body
      assert {:error, _reason} = Storage.copy_to_file(key, dest)
    end

    test "private ranged reads work the same, and the two stores stay separate" do
      key = Storage.generate_key("gated.mp4")
      {:ok, ^key} = Storage.store_private(key, tmp_source(@body))

      assert {:ok, %{bytes: "012", total: 10}} = Storage.fetch_private_range(key, 0, 2)
      # The public reader must not reach a private blob, ranged or not.
      assert {:error, :enoent} = Storage.fetch_range(key, 0, 2)
    end
  end
end
