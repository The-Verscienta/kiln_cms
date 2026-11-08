defmodule KilnCMS.Backups.ChecksumTest do
  # async: false: the bounded-memory tests sample VM-wide :erlang.memory/1, so
  # another test allocating binaries concurrently would move the needle.
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.Checksum

  @moduletag :tmp_dir

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  defp write!(dir, name, data) do
    path = Path.join(dir, name)
    File.write!(path, data)
    path
  end

  describe "file/1" do
    test "matches an independent hash and counts bytes", %{tmp_dir: dir} do
      data = :crypto.strong_rand_bytes(3_000_000)
      path = write!(dir, "a.bin", data)
      expected = sha(data)

      assert {:ok, ^expected, 3_000_000} = Checksum.file(path)
    end

    test "the empty file hashes to the well-known digest", %{tmp_dir: dir} do
      path = write!(dir, "empty", "")

      assert {:ok, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", 0} =
               Checksum.file(path)
    end

    test "a missing file is an error, not a raise", %{tmp_dir: dir} do
      assert {:error, :enoent} = Checksum.file(Path.join(dir, "nope"))
    end
  end

  describe "concat/1" do
    test "per-file digests plus the digest of the concatenation, in order", %{tmp_dir: dir} do
      a = :crypto.strong_rand_bytes(1_500_000)
      b = "tail"
      pa = write!(dir, "a", a)
      pb = write!(dir, "b", b)

      assert {:ok, result} = Checksum.concat([pa, pb])
      assert result.sha256 == sha(a <> b)
      assert result.bytes == byte_size(a) + 4
      assert [%{path: ^pa, sha256: ha, bytes: 1_500_000}, %{path: ^pb, sha256: hb}] = result.files
      assert ha == sha(a)
      assert hb == sha(b)
    end

    test "order matters", %{tmp_dir: dir} do
      pa = write!(dir, "a", "A")
      pb = write!(dir, "b", "B")
      {:ok, ab} = Checksum.concat([pa, pb])
      {:ok, ba} = Checksum.concat([pb, pa])
      assert ab.sha256 == sha("AB")
      assert ba.sha256 == sha("BA")
    end

    test "one unreadable file fails the whole call; no files is an error", %{tmp_dir: dir} do
      pa = write!(dir, "a", "A")
      assert {:error, :enoent} = Checksum.concat([pa, Path.join(dir, "gone")])
      assert {:error, :no_files} = Checksum.concat([])
    end
  end

  describe "verify/2" do
    test "ok on a match (either case), mismatch otherwise", %{tmp_dir: dir} do
      path = write!(dir, "a", "hello")
      assert :ok = Checksum.verify(path, sha("hello"))
      assert :ok = Checksum.verify(path, String.upcase(sha("hello")))
      assert {:error, :mismatch} = Checksum.verify(path, sha("hellp"))
      assert {:error, :mismatch} = Checksum.verify(path, nil)
      assert {:error, :mismatch} = Checksum.verify(path, "")
    end

    test "a flipped byte is caught", %{tmp_dir: dir} do
      data = :crypto.strong_rand_bytes(2_500_000)
      path = write!(dir, "a", data)
      good = sha(data)
      assert :ok = Checksum.verify(path, good)

      <<head::binary-size(1_234_567), byte, rest::binary>> = data
      File.write!(path, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)
      assert {:error, :mismatch} = Checksum.verify(path, good)
    end

    test "an unreadable file is the read error", %{tmp_dir: dir} do
      assert {:error, :enoent} = Checksum.verify(Path.join(dir, "gone"), sha("x"))
    end
  end

  describe "sidecar" do
    test "write then parse round-trips in order, mode 0600, no .partial left", %{tmp_dir: dir} do
      path = Path.join(dir, "kiln-media-20260805-031700.sha256")
      h1 = sha("1")
      h2 = sha("2")

      names = [
        "kiln-media-20260805-031700.part01.tar.gz",
        "kiln-media-20260805-031700.part02.tar.gz"
      ]

      assert :ok = Checksum.write_sidecar(path, Enum.zip(names, [h1, String.upcase(h2)]))

      assert File.read!(path) ==
               "#{h1}  #{Enum.at(names, 0)}\n#{h2}  #{Enum.at(names, 1)}\n"

      assert {:ok, [{^h1, n1}, {^h2, n2}]} = Checksum.parse_sidecar(path)
      assert [n1, n2] == names
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      refute File.exists?(path <> ".partial")
    end

    test "is in the format `sha256sum -c` reads", %{tmp_dir: dir} do
      case System.find_executable("sha256sum") || System.find_executable("shasum") do
        nil ->
          :ok

        tool ->
          args = if Path.basename(tool) == "shasum", do: ["-a", "256", "-c"], else: ["-c"]
          write!(dir, "one.bin", "payload")
          path = Path.join(dir, "set.sha256")
          :ok = Checksum.write_sidecar(path, [{"one.bin", sha("payload")}])

          assert {_, 0} =
                   System.cmd(tool, args ++ ["set.sha256"], cd: dir, stderr_to_stdout: true)

          File.write!(Path.join(dir, "one.bin"), "tampered")

          assert {_, status} =
                   System.cmd(tool, args ++ ["set.sha256"], cd: dir, stderr_to_stdout: true)

          assert status != 0
      end
    end

    test "refuses names that could forge lines or escape the directory", %{tmp_dir: dir} do
      path = Path.join(dir, "x.sha256")

      for bad <- ["a/b", "../x", "a\nb", "", "..", "a\\b"] do
        assert {:error, :invalid_name} = Checksum.write_sidecar(path, [{bad, sha("x")}])
        refute File.exists?(path)
      end

      assert {:error, :invalid_name} = Checksum.write_sidecar(path, [{"ok", "short"}])
      assert {:error, :invalid_name} = Checksum.write_sidecar(path, [])
    end

    test "parse is strict and reads sha256sum's binary-mode marker" do
      h = sha("x")
      assert {:ok, [{^h, "a.bin"}]} = Checksum.parse_sidecar_contents("#{h} *a.bin\n")
      assert {:ok, [{^h, "a.bin"}]} = Checksum.parse_sidecar_contents("#{h}  a.bin")

      for bad <- [
            "",
            "\n",
            "garbage\n",
            "#{String.upcase(h)}  a\n",
            "#{h}  ../a\n",
            "#{h}  dir/a\n",
            "short  a\n",
            "#{h}  a\ngarbage\n"
          ] do
        assert {:error, :malformed} = Checksum.parse_sidecar_contents(bad), inspect(bad)
      end
    end

    test "a missing sidecar is the read error", %{tmp_dir: dir} do
      assert {:error, :enoent} = Checksum.parse_sidecar(Path.join(dir, "gone.sha256"))
    end
  end

  describe "recheck/3 (#2218)" do
    test "the file it recorded passes, in either case of hex", %{tmp_dir: dir} do
      path = write!(dir, "a.bin", "the bytes it verified")
      hex = sha("the bytes it verified")

      assert :ok = Checksum.recheck(path, hex, 21)
      assert :ok = Checksum.recheck(path, String.upcase(hex), 21)
      assert :ok = Checksum.recheck(path, hex, nil)
    end

    test "one flipped byte at the same size is caught, with what was found", %{tmp_dir: dir} do
      path = write!(dir, "a.bin", "abcdef")
      hex = sha("abcdef")
      File.write!(path, "abcdeg")
      found = sha("abcdeg")

      assert {:error, {:changed, %{expected: ^hex, actual: ^found, expected_bytes: 6, bytes: 6}}} =
               Checksum.recheck(path, hex, 6)
    end

    test "a truncated or grown file is changed", %{tmp_dir: dir} do
      path = write!(dir, "a.bin", "abcdef")
      hex = sha("abcdef")

      File.write!(path, "abc")
      assert {:error, {:changed, %{bytes: 3, expected_bytes: 6}}} = Checksum.recheck(path, hex, 6)

      File.write!(path, "abcdefg")
      assert {:error, {:changed, %{bytes: 7}}} = Checksum.recheck(path, hex, 6)
    end

    test "the right digest at the wrong recorded size is still refused", %{tmp_dir: dir} do
      path = write!(dir, "a.bin", "abcdef")

      assert {:error, {:changed, %{bytes: 6, expected_bytes: 7}}} =
               Checksum.recheck(path, sha("abcdef"), 7)
    end

    test "a missing file is the read error", %{tmp_dir: dir} do
      assert {:error, :enoent} = Checksum.recheck(Path.join(dir, "gone"), sha("x"), 1)
    end

    test "a symlink is refused even when its target matches", %{tmp_dir: dir} do
      target = write!(dir, "real.bin", "abc")
      link = Path.join(dir, "link.bin")
      File.ln_s!(target, link)

      assert {:error, :not_regular} = Checksum.recheck(link, sha("abc"), 3)
    end

    test "no digest on record is refused without reading anything", %{tmp_dir: dir} do
      path = write!(dir, "a.bin", "abc")
      assert {:error, :no_digest} = Checksum.recheck(path, nil, 3)
      assert {:error, :no_digest} = Checksum.recheck(Path.join(dir, "gone"), nil, nil)
    end
  end

  describe "check_sidecar/2 (#2218)" do
    setup %{tmp_dir: dir} do
      entries = [{"p01.tar.gz", sha("one")}, {"p02.tar.gz", sha("two")}]
      path = Path.join(dir, "set.sha256")
      :ok = Checksum.write_sidecar(path, entries)
      %{path: path, entries: entries}
    end

    test "the sidecar it wrote passes", %{path: path, entries: entries} do
      assert :ok = Checksum.check_sidecar(path, entries)

      upper = Enum.map(entries, fn {n, h} -> {n, String.upcase(h)} end)
      assert :ok = Checksum.check_sidecar(path, upper)
    end

    test "a changed digest is refused", %{path: path, entries: [{n1, _}, e2] = entries} do
      File.write!(path, "#{sha("other")}  #{n1}\n#{elem(e2, 1)}  #{elem(e2, 0)}\n")
      assert {:error, :sidecar_changed} = Checksum.check_sidecar(path, entries)
    end

    test "swapped lines are refused", %{path: path, entries: [{n1, h1}, {n2, h2}] = entries} do
      File.write!(path, "#{h2}  #{n2}\n#{h1}  #{n1}\n")
      assert {:error, :sidecar_changed} = Checksum.check_sidecar(path, entries)
    end

    test "an extra line is refused", %{path: path, entries: entries} do
      File.write!(path, File.read!(path) <> "#{sha("three")}  p03.tar.gz\n")
      assert {:error, :sidecar_changed} = Checksum.check_sidecar(path, entries)
    end

    test "a missing line is refused", %{path: path, entries: [{n1, h1} | _] = entries} do
      File.write!(path, "#{h1}  #{n1}\n")
      assert {:error, :sidecar_changed} = Checksum.check_sidecar(path, entries)
    end

    test "a truncated digest is malformed", %{path: path, entries: [{n1, h1}, {n2, h2}] = entries} do
      File.write!(path, "#{h1}  #{n1}\n#{String.slice(h2, 0, 40)}  #{n2}\n")
      assert {:error, :malformed} = Checksum.check_sidecar(path, entries)
    end

    test "a missing sidecar is the read error", %{tmp_dir: dir, entries: entries} do
      assert {:error, :enoent} = Checksum.check_sidecar(Path.join(dir, "gone.sha256"), entries)
    end

    test "a symlinked sidecar is refused", %{tmp_dir: dir, path: path, entries: entries} do
      link = Path.join(dir, "link.sha256")
      File.ln_s!(path, link)
      assert {:error, :not_regular} = Checksum.check_sidecar(link, entries)
    end

    test "an entry with no digest on record is refused", %{path: path, entries: [e1, {n2, _}]} do
      assert {:error, :no_digest} = Checksum.check_sidecar(path, [e1, {n2, nil}])
      assert {:error, :no_digest} = Checksum.check_sidecar(path, [])
    end
  end

  describe "bounded memory" do
    # Polls the VM's total memory while `fun` runs and returns the peak growth
    # over the starting level, in bytes. Binary memory is where a whole-file
    # read would show up (refc binaries); total covers everything else.
    defp peak_growth(fun) do
      :erlang.garbage_collect()
      base_total = :erlang.memory(:total)
      base_binary = :erlang.memory(:binary)
      parent = self()

      sampler =
        spawn_link(fn ->
          sample_loop(parent, base_total, base_binary, 0)
        end)

      result = fun.()
      send(sampler, :stop)

      peak =
        receive do
          {:peak, peak} -> peak
        after
          5_000 -> flunk("memory sampler did not report")
        end

      {result, peak}
    end

    defp sample_loop(parent, base_total, base_binary, peak) do
      peak =
        max(peak, max(:erlang.memory(:total) - base_total, :erlang.memory(:binary) - base_binary))

      receive do
        :stop -> send(parent, {:peak, peak})
      after
        10 -> sample_loop(parent, base_total, base_binary, peak)
      end
    end

    defp sparse!(path, bytes) do
      {:ok, io} = :file.open(path, [:write, :raw, :binary])
      {:ok, _} = :file.position(io, bytes - 1)
      :ok = :file.write(io, <<0>>)
      :ok = :file.close(io)
    end

    defp assert_bounded(dir, bytes) do
      path = Path.join(dir, "sparse.bin")
      sparse!(path, bytes)
      assert File.stat!(path).size == bytes

      {result, peak} = peak_growth(fn -> Checksum.file(path) end)

      assert {:ok, hex, ^bytes} = result
      assert byte_size(hex) == 64
      assert peak < 32 * 1_048_576, "peak memory grew by #{div(peak, 1_048_576)} MB"
    end

    test "hashing a 1 GiB sparse file stays far below its size", %{tmp_dir: dir} do
      assert_bounded(dir, 1_073_741_824)
    end

    @tag :backup_scale
    @tag timeout: 600_000
    test "hashing a 3 GiB sparse file stays far below its size", %{tmp_dir: dir} do
      assert_bounded(dir, 3 * 1_073_741_824)
    end
  end
end
