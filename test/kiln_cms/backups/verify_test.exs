defmodule KilnCMS.Backups.VerifyTest do
  @moduledoc """
  `KilnCMS.Backups.Verify` (#2234): `bin/backup verify` re-checks a recorded
  backup's files on this host and records nothing.

  Media sets need no `pg_restore`; a dump is listed by a stub `pg_restore`
  script passed through the `:pg_restore` seam.

  `async: false`: it changes the VM-wide `KilnCMS.Backups` env (`:dir`).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, DirId, Verify}

  @stamp "20261118-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_verify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp write_file!(dir, sub, name, data) do
    path = Path.join([dir, sub, name])
    File.write!(path, data)
    {name, sha(data), byte_size(data)}
  end

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  # A media set of `n` parts on disk, its sidecar, and its row.
  defp media_set!(dir, n, opts \\ []) do
    stamp = Keyword.get(opts, :stamp, @stamp)
    datas = for i <- 1..n, do: :crypto.strong_rand_bytes(200 + i)
    names = Artifact.set_names(stamp, n)

    files =
      for {name, data} <- Enum.zip(names, datas), do: write_file!(dir, "media", name, data)

    :ok =
      Checksum.write_sidecar(
        Path.join([dir, "media", Artifact.sidecar_name(:media, stamp)]),
        Enum.map(files, fn {name, hex, _bytes} -> {name, hex} end)
      )

    artifact =
      if n == 1 do
        [{name, hex, bytes}] = files
        %{kind: :media, name: name, bytes: bytes, sha256: hex, verified: true}
      else
        %{
          kind: :media,
          name: "kiln-media-#{stamp}",
          bytes: files |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
          sha256: sha(Enum.join(datas)),
          verified: true,
          parts:
            for(
              {name, hex, bytes} <- files,
              do: %{"name" => name, "sha256" => hex, "bytes" => bytes}
            )
        }
      end

    {import!(stamp, [artifact], opts), files}
  end

  defp import!(stamp, artifacts, opts \\ []) do
    Backups.import_run!(
      %{
        stamp: stamp,
        trigger: "cron",
        status: Keyword.get(opts, :status, :succeeded),
        components: Enum.map(artifacts, & &1.kind) |> Enum.uniq(),
        started_at: ~U[2026-11-18 03:17:00.000000Z],
        finished_at: ~U[2026-11-18 03:20:00.000000Z],
        artifacts: artifacts
      },
      actor: Backups.system()
    )
  end

  defp flip_byte!(path, at) do
    data = File.read!(path)
    <<head::binary-size(^at), byte, tail::binary>> = data
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)
  end

  defp verify(run, opts \\ []), do: Verify.run(run, Keyword.put_new(opts, :in_flight, nil))

  defp failed(report), do: Enum.filter(report.checks, &(&1.result == :failed))

  defp stub_pg_restore!(dir, status) do
    path = Path.join(dir, "pg_restore_stub")
    File.write!(path, "#!/bin/sh\necho 'listing password=hunter2'\nexit #{status}\n")
    File.chmod!(path, 0o755)
    path
  end

  test "a good single-file set verifies", %{dir: dir} do
    {run, _files} = media_set!(dir, 1)

    assert {:ok, %{verified: true, hashed: 1, failed: 0} = report} = verify(run)
    assert Enum.map(report.checks, & &1.check) == [:sha256, :sidecar]
    assert [%{recorded_verified: true, result: :ok}] = report.artifacts
  end

  test "a good three-part set verifies, set digest included", %{dir: dir} do
    {run, _files} = media_set!(dir, 3)

    assert {:ok, %{verified: true, hashed: 3} = report} = verify(run)
    assert [%{result: :ok}] = Enum.filter(report.checks, &(&1.check == :set_sha256))
  end

  test "one changed byte in part 2 fails part 2's sha256 check", %{dir: dir} do
    {run, [_p1, {p2, _, _}, _p3]} = media_set!(dir, 3)
    flip_byte!(Path.join([dir, "media", p2]), 100)

    assert {:ok, %{verified: false} = report} = verify(run)

    assert [%{file: ^p2, check: :sha256, code: :changed}] = failed(report)
    assert [%{result: :failed}] = report.artifacts
  end

  test "a same-sized file with one different byte is caught by the hash", %{dir: dir} do
    {run, [{name, _hex, bytes}]} = media_set!(dir, 1)
    path = Path.join([dir, "media", name])
    flip_byte!(path, 0)
    assert File.stat!(path).size == bytes

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{check: :sha256, code: :changed}] = failed(report)
  end

  test "a missing part is named", %{dir: dir} do
    {run, [_p1, {p2, _, _}, _p3]} = media_set!(dir, 3)
    File.rm!(Path.join([dir, "media", p2]))

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{file: ^p2, check: :present, code: :missing}] = failed(report)
  end

  test "a symlink in place of a file is refused, not followed", %{dir: dir} do
    {run, [{name, _hex, _bytes}]} = media_set!(dir, 1)
    path = Path.join([dir, "media", name])
    real = Path.join(dir, "elsewhere")
    File.rename!(path, real)
    File.ln_s!(real, path)

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{check: :present, code: :not_regular}] = failed(report)
  end

  test "a sidecar changed after the backup fails", %{dir: dir} do
    {run, [{name, _hex, _bytes}]} = media_set!(dir, 1)
    sidecar = Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)])
    File.write!(sidecar, "#{String.duplicate("0", 64)}  #{name}\n")

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{check: :sidecar, code: :sidecar_changed}] = failed(report)
  end

  test "a missing sidecar fails", %{dir: dir} do
    {run, _files} = media_set!(dir, 1)
    File.rm!(Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]))

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{check: :sidecar, code: :sidecar_missing}] = failed(report)
  end

  test "a row with no digest is checked against the sidecar", %{dir: dir} do
    {name, hex, bytes} = write_file!(dir, "media", "kiln-media-#{@stamp}.tar.gz", "abc")

    :ok =
      Checksum.write_sidecar(Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]), [
        {name, hex}
      ])

    run = import!(@stamp, [%{kind: :media, name: name, bytes: bytes}])

    assert {:ok, %{verified: true} = report} = verify(run)
    assert [%{check: :sha256, detail: "matches the sidecar" <> _}] = report.checks
  end

  test "no digest anywhere fails as no_digest", %{dir: dir} do
    {name, _hex, bytes} = write_file!(dir, "media", "kiln-media-#{@stamp}.tar.gz", "abc")
    run = import!(@stamp, [%{kind: :media, name: name, bytes: bytes}])

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{check: :sha256, code: :no_digest}] = failed(report)
  end

  describe "a dump" do
    setup %{dir: dir} do
      {name, hex, bytes} = write_file!(dir, "db", "kiln-db-#{@stamp}.dump", "PGDMP fake")

      :ok =
        Checksum.write_sidecar(Path.join([dir, "db", Artifact.sidecar_name(:db, @stamp)]), [
          {name, hex}
        ])

      run = import!(@stamp, [%{kind: :db, name: name, bytes: bytes, sha256: hex}])
      %{run: run}
    end

    test "is listed with pg_restore --list", %{dir: dir, run: run} do
      assert {:ok, %{verified: true} = report} = verify(run, pg_restore: stub_pg_restore!(dir, 0))
      assert [:sha256, :sidecar, :pg_restore] = Enum.map(report.checks, & &1.check)
    end

    test "fails when pg_restore is missing, even with a matching digest", %{run: run} do
      assert {:ok, %{verified: false} = report} =
               verify(run, pg_restore: "definitely-not-installed-pg_restore")

      assert [%{check: :pg_restore, code: :pg_restore_missing}] = failed(report)
      assert [%{check: :sha256, result: :ok} | _] = report.checks
    end

    test "fails when pg_restore can't list it, with its output redacted", %{dir: dir, run: run} do
      assert {:ok, %{verified: false} = report} =
               verify(run, pg_restore: stub_pg_restore!(dir, 1))

      assert [%{check: :pg_restore, code: :pg_restore_list, detail: detail}] = failed(report)
      refute detail =~ "hunter2"
    end
  end

  test "a name that leaves the directory is refused before any file is opened", %{dir: dir} do
    outside = Path.join(Path.dirname(dir), "kiln-db-#{@stamp}.dump")

    run =
      import!(@stamp, [
        %{kind: :db, name: "../kiln-db-#{@stamp}.dump", bytes: 1, sha256: sha("x")}
      ])

    assert {:ok, %{verified: false} = report} = verify(run)
    assert [%{check: :name, code: :unsafe_name}] = report.checks
    refute File.exists?(outside)
  end

  test "a part named for another stamp, or out of order, is refused", %{dir: dir} do
    {run, _files} = media_set!(dir, 2)
    [one, two] = hd(run.artifacts).parts
    swapped = %{hd(run.artifacts) | parts: [two, one]}

    assert {:ok, %{verified: false} = report} = verify(%{run | artifacts: [swapped]})
    assert [%{code: :unsafe_name}] = report.checks

    other = %{
      hd(run.artifacts)
      | parts: [%{one | "name" => "kiln-media-20200101-000000.part01.tar.gz"}, two]
    }

    assert {:ok, %{checks: [%{code: :unsafe_name}]}} = verify(%{run | artifacts: [other]})
  end

  test "a running backup is refused", %{dir: dir} do
    {run, _files} = media_set!(dir, 1, status: :running)
    assert {:error, :in_progress} = verify(run)
  end

  test "a backup whose stamp the lock holds is refused", %{dir: dir} do
    {run, _files} = media_set!(dir, 1)
    assert {:error, :in_progress} = Verify.run(run, in_flight: %{stamp: @stamp})
  end

  test "a pruned part is skipped, not missing; the rest are checked", %{dir: dir} do
    {run, [{p1, _, _}, _p2]} = media_set!(dir, 2)
    File.rm!(Path.join([dir, "media", p1]))
    [one, two] = hd(run.artifacts).parts
    pruned = Map.put(one, "destinations", %{"local" => %{"status" => "pruned"}})
    run = %{run | artifacts: [%{hd(run.artifacts) | parts: [pruned, two]}]}

    assert {:ok, %{verified: true, hashed: 1} = report} = verify(run)

    assert [%{file: ^p1, result: :skipped, code: :pruned}] =
             Enum.filter(report.checks, &(&1.check == :present))

    # The set digest can't be checked with a part gone.
    refute Enum.any?(report.checks, &(&1.check == :set_sha256))
  end

  test "a set the cron prune removed is skipped, as History judges it", %{dir: dir} do
    # An imported run years old, with a newer complete unit beside it and a
    # cron manifest's window: History calls it expired.
    {old, files} = media_set!(dir, 1, stamp: "20200101-000000")
    for {name, _, _} <- files, do: File.rm!(Path.join([dir, "media", name]))
    {_newer, _} = media_set!(dir, 1)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{
        "status" => "ok",
        "source" => "cron",
        "started_at" => "2026-11-18T03:17:00Z",
        "finished_at" => "2026-11-18T03:20:00Z",
        "keep_days" => 14,
        "artifacts" => []
      })
    )

    old = %{
      old
      | started_at: ~U[2020-01-01 00:00:00.000000Z],
        finished_at: ~U[2020-01-01 00:01:00.000000Z]
    }

    assert {:ok, %{verified: false, hashed: 0, failed: 0} = report} = verify(old)
    assert [%{result: :skipped, code: code}] = report.checks
    assert code in [:expired, :probably_expired]
  end

  test "every artifact pruned: nothing hashed, not verified", %{dir: dir} do
    {run, files} = media_set!(dir, 1)
    for {name, _, _} <- files, do: File.rm!(Path.join([dir, "media", name]))
    artifact = %{hd(run.artifacts) | destinations: %{"local" => %{"status" => "pruned"}}}

    assert {:ok, %{verified: false, hashed: 0, failed: 0}} =
             verify(%{run | artifacts: [artifact]})
  end

  test "an off-site-only file is skipped, never fetched", %{dir: dir} do
    {run, files} = media_set!(dir, 1)
    for {name, _, _} <- files, do: File.rm!(Path.join([dir, "media", name]))

    artifact = %{
      hd(run.artifacts)
      | destinations: %{"local" => %{"status" => "ok"}, "rclone:offsite" => %{"status" => "ok"}}
    }

    assert {:ok, %{verified: false, checks: [%{result: :skipped, code: :off_site_only}]}} =
             verify(%{run | artifacts: [artifact]})
  end

  test "a missing file of a run recorded on another node says so", %{dir: dir} do
    {run, files} = media_set!(dir, 1)
    for {name, _, _} <- files, do: File.rm!(Path.join([dir, "media", name]))
    {:ok, _here} = DirId.ensure_existing(dir)
    other = Ecto.UUID.generate()

    assert {:ok, %{dir_id_mismatch: true} = report} = verify(%{run | dir_id: other})
    assert [%{code: :missing, detail: detail}] = failed(report)
    assert detail =~ "another node's backup directory (#{other})"
  end

  test "verifying changes nothing on the row", %{dir: dir} do
    {run, _files} = media_set!(dir, 3)
    flip_byte!(Path.join([dir, "media", hd(Artifact.files(hd(run.artifacts)))]), 5)
    before = Backups.get_run!(run.id, actor: Backups.system())

    assert {:ok, %{verified: false}} = verify(run)
    assert Backups.get_run!(run.id, actor: Backups.system()) == before
  end
end
