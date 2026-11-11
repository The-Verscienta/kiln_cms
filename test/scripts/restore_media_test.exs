defmodule KilnCMS.Scripts.RestoreMediaTest do
  @moduledoc """
  `scripts/restore.sh media` against real part sets (#2218).

  The sets are built with the app's own pipeline (`MediaArchive` plus the
  `Checksum` sidecar), so what is tested is that the shell side reads exactly
  what the app writes. The traversal cases need archives `tar` itself refuses
  to create, so those are assembled with `:erl_tar`, which stores member names
  verbatim.

  Skipped, with the reason, where bash, tar or a sha256 tool is missing.

  `async: false`: it spawns processes and shares the tmp dir namespace with the
  other backup tests, and the part-size cases are timing-heavy enough that
  running alongside the suite adds nothing.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.{Artifact, Checksum, MediaArchive}

  @script Path.expand("../../scripts/restore.sh", __DIR__)
  @stamp "20260805-031700"

  tools = ["bash", "tar", "gzip"]
  missing = Enum.reject(tools, &System.find_executable/1)

  sha_tool? = System.find_executable("sha256sum") || System.find_executable("shasum")

  cond do
    missing != [] ->
      @moduletag skip: "needs #{Enum.join(missing, ", ")} on PATH"

    !sha_tool? ->
      @moduletag skip: "needs sha256sum or shasum on PATH"

    true ->
      :ok
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "kiln_restore_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    media = Path.join(tmp, "source")
    backups = Path.join(tmp, "backups/media")
    dest = Path.join(tmp, "restore/media")
    File.mkdir_p!(backups)
    populate!(media)

    %{tmp: tmp, media: media, backups: backups, dest: dest}
  end

  describe "multi-part sets" do
    test "restoring from the first part rebuilds the whole tree", ctx do
      parts = build_set!(ctx, @stamp, 700)
      assert length(parts) >= 3

      assert {out, 0} = restore(ctx, [hd(parts)])
      assert out =~ "Verifying checksums from kiln-media-#{@stamp}.sha256"
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "any part finds its siblings (a middle part)", ctx do
      parts = build_set!(ctx, @stamp, 700)

      assert {_out, 0} = restore(ctx, [Enum.at(parts, 1)])
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "several explicit paths, in any order, are the set", ctx do
      parts = build_set!(ctx, @stamp, 700)

      assert {_out, 0} = restore(ctx, Enum.reverse(parts))
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "a shell glob of the parts works", ctx do
      build_set!(ctx, @stamp, 700)
      glob = Path.wildcard(Path.join(ctx.backups, "kiln-media-#{@stamp}.part*.tar.gz"))

      assert {_out, 0} = restore(ctx, glob)
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "a stamp prefix names the set", ctx do
      build_set!(ctx, @stamp, 700)

      assert {_out, 0} = restore(ctx, [Path.join(ctx.backups, "kiln-media-#{@stamp}")])
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "parts are extracted in NUMERIC order, past part99", ctx do
      # 101 tiny archives that all hold `same.txt`, whose content is the part
      # number: whichever part extracts last wins, so the result shows the
      # order. Glob/lexicographic order would put part100 before part11.
      names = for n <- 1..101, do: Artifact.part_name(@stamp, n)

      for {name, n} <- Enum.with_index(names, 1) do
        tar!(Path.join(ctx.backups, name), [{"same.txt", Integer.to_string(n)}])
      end

      write_sidecar!(ctx.backups, names)

      assert {_out, 0} = restore(ctx, [Path.join(ctx.backups, hd(names))])
      assert File.read!(Path.join(ctx.dest, "same.txt")) == "101"
    end
  end

  describe "a single legacy archive" do
    test "is restored as is", ctx do
      assert [archive] = build_set!(ctx, @stamp, 10_000_000)
      assert Path.basename(archive) == "kiln-media-#{@stamp}.tar.gz"

      assert {out, 0} = restore(ctx, [archive])
      assert out =~ "Verifying checksums"
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "without a sidecar it is still restored, with the warning (pre-checksum backups)",
         ctx do
      assert [archive] = build_set!(ctx, @stamp, 10_000_000)
      File.rm!(Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256"))

      assert {out, 0} = restore(ctx, [archive])
      assert out =~ "WARNING: no checksum found"
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "an archive not named by Kiln is accepted, with the no-checksum banner", ctx do
      [archive] = build_set!(ctx, @stamp, 10_000_000)
      odd = Path.join(ctx.backups, "my-uploads.tar.gz")
      File.cp!(archive, odd)

      assert {out, 0} = restore(ctx, [odd])
      assert out =~ "WARNING: no checksum"
      assert tree(ctx.dest) == tree(ctx.media)
    end
  end

  describe "refusing a bad set" do
    test "a missing middle part fails clearly and extracts nothing", ctx do
      [p1, p2 | _] = build_set!(ctx, @stamp, 700)
      File.rm!(p2)

      assert {out, status} = restore(ctx, [p1])
      assert status != 0
      assert out =~ "missing part02"
      assert nothing_extracted?(ctx)
    end

    test "explicit paths with a gap fail the same way", ctx do
      [p1, _p2, p3 | _] = build_set!(ctx, @stamp, 700)

      assert {out, status} = restore(ctx, [p1, p3])
      assert status != 0
      assert out =~ "missing part02"
      assert nothing_extracted?(ctx)
    end

    test "a missing LAST part is caught by the sidecar", ctx do
      parts = build_set!(ctx, @stamp, 700)
      File.rm!(List.last(parts))

      assert {out, status} = restore(ctx, [hd(parts)])
      assert status != 0
      assert out =~ "is missing from the set"
      assert nothing_extracted?(ctx)
    end

    test "a duplicate part fails", ctx do
      [p1, p2 | rest] = build_set!(ctx, @stamp, 700)

      assert {out, status} = restore(ctx, [p1, p2, p2 | rest])
      assert status != 0
      assert out =~ "duplicate part02"
      assert nothing_extracted?(ctx)
    end

    test "parts of two stamps are refused", ctx do
      [a | _] = build_set!(ctx, @stamp, 700)
      [b | _] = build_set!(ctx, "20260806-031700", 700)

      assert {out, status} = restore(ctx, [a, b])
      assert status != 0
      assert out =~ "refusing to mix stamps"
      assert nothing_extracted?(ctx)
    end

    test "an unknown path is an error", ctx do
      assert {out, status} = restore(ctx, [Path.join(ctx.backups, "kiln-media-nope")])
      assert status != 0
      assert out =~ "no such file"
    end
  end

  describe "checksums" do
    test "a flipped byte fails BEFORE anything is extracted", ctx do
      [p1, p2 | _] = build_set!(ctx, @stamp, 700)
      flip_byte!(p2)

      assert {out, status} = restore(ctx, [p1])
      assert status != 0
      assert out =~ "FAILED"
      assert nothing_extracted?(ctx)
    end

    test "the sidecar is enough: no manifest, or a newer run's manifest", ctx do
      [p1 | _] = build_set!(ctx, @stamp, 700)
      manifest = Path.join(ctx.tmp, "backups/manifest.json")

      # Gone.
      assert {_out, 0} = restore(ctx, [p1])
      File.rm_rf!(ctx.dest)

      # Replaced by a different (newer) run that knows nothing of these files.
      File.write!(manifest, ~s({"version":1,"ok":true,"artifacts":[]}))
      assert {out, 0} = restore(ctx, [p1])
      assert out =~ "Verifying checksums from"
      File.rm_rf!(ctx.dest)

      # ...and it still catches corruption.
      flip_byte!(p1)
      assert {_out, status} = restore(ctx, [p1])
      assert status != 0
      assert nothing_extracted?(ctx)
    end

    test "no sidecar: a part set is refused, since every complete set has one", ctx do
      [p1 | _] = build_set!(ctx, @stamp, 700)
      File.rm!(Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256"))

      assert {out, status} = restore(ctx, [p1])
      assert status != 0
      assert out =~ "WARNING: no checksum found"
      assert out =~ "has no sidecar, so it is probably incomplete"
      assert out =~ "RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1"
      assert nothing_extracted?(ctx)
    end

    test "no sidecar with RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM=1: a loud warning, then the restore",
         ctx do
      [p1 | _] = build_set!(ctx, @stamp, 700)
      File.rm!(Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256"))

      assert {out, 0} = restore(ctx, [p1], [{"RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM", "1"}])
      assert out =~ "WARNING: no checksum found"
      assert out =~ "kiln-media-#{@stamp}.sha256"
      assert tree(ctx.dest) == tree(ctx.media)
    end

    test "what a killed cron run leaves (first parts, the marker, no sidecar) is refused", ctx do
      [_p1, _p2, p3 | rest] = build_set!(ctx, @stamp, 700)
      sidecar = Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256")
      File.rm!(sidecar)
      for p <- [p3 | rest], do: File.rm!(p)
      File.write!(sidecar <> ".partial", "")

      assert {out, status} =
               restore(ctx, [hd(Path.wildcard(Path.join(ctx.backups, "*.part01.*")))], [
                 {"RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM", "1"}
               ])

      assert status != 0
      assert out =~ "kiln-media-#{@stamp}.sha256.partial is beside the set"
      assert nothing_extracted?(ctx)

      # Once the marker is gone (the app sweeps stale partials after an hour),
      # the missing sidecar still stops it.
      File.rm!(sidecar <> ".partial")
      assert {out, status} = restore(ctx, [Path.join(ctx.backups, "kiln-media-#{@stamp}")])
      assert status != 0
      assert out =~ "has no sidecar, so it is probably incomplete"
      assert nothing_extracted?(ctx)
    end

    test "a part still being written beside the set is refused", ctx do
      parts = build_set!(ctx, @stamp, 700)
      File.write!(List.last(parts) <> ".partial", "in flight")

      assert {out, status} = restore(ctx, [hd(parts)])
      assert status != 0
      assert out =~ ".tar.gz.partial is beside the set"
      assert nothing_extracted?(ctx)
    end

    test "no sidecar with RESTORE_REQUIRE_CHECKSUM=1 aborts", ctx do
      [p1 | _] = build_set!(ctx, @stamp, 700)
      File.rm!(Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256"))

      assert {out, status} = restore(ctx, [p1], [{"RESTORE_REQUIRE_CHECKSUM", "1"}])
      assert status != 0
      assert out =~ "RESTORE_REQUIRE_CHECKSUM=1"
      assert nothing_extracted?(ctx)
    end
  end

  describe "extraction safety" do
    test "a part holding ../evil is refused before ANY part is extracted", ctx do
      names = [Artifact.part_name(@stamp, 1), Artifact.part_name(@stamp, 2)]
      File.rm_rf!(ctx.backups)
      File.mkdir_p!(ctx.backups)
      tar!(Path.join(ctx.backups, Enum.at(names, 0)), [{"fine.txt", "ok"}])
      tar!(Path.join(ctx.backups, Enum.at(names, 1)), [{"../evil", "pwned"}])
      write_sidecar!(ctx.backups, names)

      assert {out, status} = restore(ctx, [Path.join(ctx.backups, hd(names))])
      assert status != 0
      assert out =~ "refusing to extract"
      refute File.exists?(Path.join(Path.dirname(ctx.dest), "evil"))
      assert nothing_extracted?(ctx)
    end

    test "a nested ../ component is refused too", ctx do
      name = "kiln-media-#{@stamp}.tar.gz"
      tar!(Path.join(ctx.backups, name), [{"a/../../evil", "pwned"}])
      write_sidecar!(ctx.backups, [name])

      assert {_out, status} = restore(ctx, [Path.join(ctx.backups, name)])
      assert status != 0
      refute File.exists?(Path.join(Path.dirname(ctx.dest), "evil"))
      assert nothing_extracted?(ctx)
    end

    test "an absolute member path is refused", ctx do
      target = Path.join(ctx.tmp, "abs-evil")
      name = "kiln-media-#{@stamp}.tar.gz"
      tar!(Path.join(ctx.backups, name), [{target, "pwned"}])
      write_sidecar!(ctx.backups, [name])

      assert {out, status} = restore(ctx, [Path.join(ctx.backups, name)])
      assert status != 0
      assert out =~ "refusing to extract"
      refute File.exists?(target)
      assert nothing_extracted?(ctx)
    end

    test "an ordinary dotted name is not mistaken for traversal", ctx do
      name = "kiln-media-#{@stamp}.tar.gz"
      tar!(Path.join(ctx.backups, name), [{"a/..hidden/v1..2.txt", "fine"}])
      write_sidecar!(ctx.backups, [name])

      assert {_out, 0} = restore(ctx, [Path.join(ctx.backups, name)])
      assert File.read!(Path.join(ctx.dest, "a/..hidden/v1..2.txt")) == "fine"
    end
  end

  describe "unreadable and hostile archives" do
    test "a truncated part with no sidecar extracts NOTHING", ctx do
      [_p1, _p2, p3 | _] = build_set!(ctx, @stamp, 700)
      File.rm!(Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256"))
      bytes = File.read!(p3)
      File.write!(p3, binary_part(bytes, 0, div(byte_size(bytes), 2)))

      assert {out, status} =
               restore(ctx, [hd(Path.wildcard(Path.join(ctx.backups, "*.part01.*")))], [
                 {"RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM", "1"}
               ])

      assert status != 0
      assert out =~ "unreadable archive"
      assert nothing_extracted?(ctx)
    end

    test "a symlink to an absolute path, then a member through it, is refused", ctx do
      victim = Path.join(ctx.tmp, "victim")
      File.mkdir_p!(victim)
      name = link_archive!(ctx, [{"x", {:link, victim}}, {"x/evil", "pwned"}])

      assert {out, status} = restore(ctx, [name])
      assert status != 0
      assert out =~ "refusing to extract"
      refute File.exists?(Path.join(victim, "evil"))
      assert nothing_extracted?(ctx)
    end

    test "a symlink with a .. target is refused", ctx do
      name = link_archive!(ctx, [{"x", {:link, "../outside"}}, {"x/evil", "pwned"}])

      assert {out, status} = restore(ctx, [name])
      assert status != 0
      assert out =~ "refusing to extract"
      refute File.exists?(Path.join(ctx.tmp, "restore/outside/evil"))
      assert nothing_extracted?(ctx)
    end

    test "a hostile link in a LATER part stops the whole set before any extraction", ctx do
      names = [Artifact.part_name(@stamp, 1), Artifact.part_name(@stamp, 2)]
      tar!(Path.join(ctx.backups, hd(names)), [{"fine.txt", "ok"}])
      link_archive!(ctx, [{"x", {:link, "/etc"}}], Enum.at(names, 1))
      write_sidecar!(ctx.backups, names)

      assert {_out, status} = restore(ctx, [Path.join(ctx.backups, hd(names))])
      assert status != 0
      assert nothing_extracted?(ctx)
    end

    test "a relative symlink inside the tree still restores", ctx do
      name = link_archive!(ctx, [{"sub/real.txt", "data"}, {"sub/alias", {:link, "real.txt"}}])

      assert {_out, 0} = restore(ctx, [name])
      assert File.read!(Path.join(ctx.dest, "sub/real.txt")) == "data"
      assert File.read_link!(Path.join(ctx.dest, "sub/alias")) == "real.txt"
    end

    test "a sidecar line with a truncated digest fails, nothing extracted", ctx do
      [p1 | _] = build_set!(ctx, @stamp, 700)
      sidecar = Path.join(ctx.backups, "kiln-media-#{@stamp}.sha256")
      [first | rest] = File.read!(sidecar) |> String.split("\n", trim: true)
      File.write!(sidecar, Enum.join([String.slice(first, 10..-1//1) | rest], "\n") <> "\n")

      assert {_out, status} = restore(ctx, [p1])
      assert status != 0
      assert nothing_extracted?(ctx)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp populate!(media) do
    files = for n <- 1..8, do: {"sub#{rem(n, 3)}/file#{n}.bin", :crypto.strong_rand_bytes(300)}
    files = [{"top level.txt", "spaces in the name"}, {"deep/er/est.bin", "deep"} | files]

    for {rel, bytes} <- files do
      path = Path.join(media, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end
  end

  # Build the set the way the app does and return the part paths in order.
  defp build_set!(ctx, stamp, part_bytes) do
    work = Path.join(ctx.tmp, "work-#{stamp}-#{part_bytes}")

    {:ok, plan} =
      MediaArchive.plan(ctx.media, work, stamp: stamp, part_bytes: part_bytes, exclude: [])

    {:ok, finished} = MediaArchive.archive(plan, ctx.backups)
    {:ok, _} = MediaArchive.checksum(plan, finished, ctx.backups)
    Enum.map(finished, & &1.path)
  end

  defp restore(ctx, args, env \\ []) do
    System.cmd("bash", [@script, "media" | args],
      env:
        [
          {"RESTORE_MEDIA_DIR", ctx.dest},
          {"RESTORE_REQUIRE_CHECKSUM", nil},
          {"RESTORE_ALLOW_PARTS_WITHOUT_CHECKSUM", nil}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp nothing_extracted?(ctx), do: not File.exists?(ctx.dest) or tree(ctx.dest) == []

  defp tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Path.relative_to(&1, root), File.read!(&1)})
    |> Enum.sort()
  end

  # :erl_tar stores member names verbatim, so it can write the `../` and
  # absolute names that `tar -c` refuses without -P.
  defp tar!(path, entries) do
    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        for({name, data} <- entries, do: {String.to_charlist(name), data}),
        [:compressed]
      )
  end

  # A one-file archive whose members may be symlinks: `{name, {:link, target}}`
  # or `{name, binary}`. Links are made on disk and stored as links (no
  # :dereference); :erl_tar keeps the member names verbatim. Returns the path.
  defp link_archive!(ctx, entries, name \\ "kiln-media-#{@stamp}.tar.gz") do
    stage = Path.join(ctx.tmp, "stage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(stage)

    members =
      for {{member, content}, n} <- Enum.with_index(entries) do
        src = Path.join(stage, "m#{n}")

        case content do
          {:link, target} -> File.ln_s!(target, src)
          data -> File.write!(src, data)
        end

        {String.to_charlist(member), String.to_charlist(src)}
      end

    path = Path.join(ctx.backups, name)
    :ok = :erl_tar.create(String.to_charlist(path), members, [:compressed])

    if name == "kiln-media-#{@stamp}.tar.gz", do: write_sidecar!(ctx.backups, [name])
    path
  end

  defp write_sidecar!(dir, names) do
    entries =
      for name <- names do
        {:ok, hex, _} = Checksum.file(Path.join(dir, name))
        {name, hex}
      end

    :ok = Checksum.write_sidecar(Path.join(dir, "kiln-media-#{@stamp}.sha256"), entries)
  end

  defp flip_byte!(path) do
    bytes = File.read!(path)
    pos = div(byte_size(bytes), 2)
    <<head::binary-size(^pos), byte, tail::binary>> = bytes
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)
  end
end
