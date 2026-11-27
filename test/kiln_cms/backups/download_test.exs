defmodule KilnCMS.Backups.DownloadTest do
  @moduledoc """
  `KilnCMS.Backups.check_download/3` and `download/4` (part of #2225): which
  local file of a run a platform admin may download, and the
  `backup_downloaded` event a download records before it hands back a path.

  The name a client sends is only ever compared with the names derived from
  the run's own row, so every traversal, partial, other-stamp or unknown name
  is the same `:not_found`, with nothing outside the backup directory looked
  at.

  `async: false`: it changes the VM-wide `KilnCMS.Backups` env (`:dir`) and
  the action's test seams (`:recorder`, `:held_stamp`).
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, DirId}
  alias KilnCMS.Backups.Run.Actions.Download
  alias KilnCMS.Security
  alias KilnCMS.Security.Recorder

  @stamp "20261118-031700"
  @other_stamp "20261117-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_dl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, dir))

    seams = Application.get_env(:kiln_cms, Download)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)

      if seams,
        do: Application.put_env(:kiln_cms, Download, seams),
        else: Application.delete_env(:kiln_cms, Download)

      File.rm_rf!(dir)
    end)

    %{dir: dir, admin: user(:admin)}
  end

  defp seam(key, value) do
    Application.put_env(
      :kiln_cms,
      Download,
      Keyword.put(Application.get_env(:kiln_cms, Download, []), key, value)
    )
  end

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "dl-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp write!(dir, sub, name, data \\ nil) do
    data = data || :crypto.strong_rand_bytes(64)
    File.write!(Path.join([dir, sub, name]), data)
    %{name: name, bytes: byte_size(data), sha256: sha(data), data: data}
  end

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  defp db_artifact(file, destinations \\ %{"local" => %{"status" => "ok"}}) do
    %{
      kind: :db,
      name: file.name,
      bytes: file.bytes,
      sha256: file.sha256,
      verified: true,
      destinations: destinations
    }
  end

  defp media_artifact(files, opts \\ []) do
    %{
      kind: :media,
      name: "kiln-media-#{@stamp}",
      bytes: files |> Enum.map(& &1.bytes) |> Enum.sum(),
      verified: true,
      destinations: Keyword.get(opts, :destinations, %{"local" => %{"status" => "ok"}}),
      parts:
        for(
          {file, i} <- Enum.with_index(files, 1),
          do:
            %{"name" => file.name, "bytes" => file.bytes, "sha256" => file.sha256}
            |> put_part_destinations(Keyword.get(opts, :part_destinations, %{})[i])
        )
    }
  end

  defp put_part_destinations(part, nil), do: part
  defp put_part_destinations(part, dests), do: Map.put(part, "destinations", dests)

  # A finished in-app run, pinned to `dir_id` (nil for none).
  defp app_run!(artifacts, opts \\ []) do
    %{
      stamp: Keyword.get(opts, :stamp, @stamp),
      trigger: "test",
      dir_id: Keyword.get(opts, :dir_id)
    }
    |> Backups.start_run!(actor: Backups.system())
    |> then(fn run ->
      if Keyword.get(opts, :running?, false),
        do: run,
        else: Backups.finish_run!(run, %{artifacts: artifacts}, actor: Backups.system())
    end)
  end

  defp import_run!(artifacts, stamp \\ @stamp) do
    Backups.import_run!(
      %{
        stamp: stamp,
        trigger: "cron",
        status: :succeeded,
        components: artifacts |> Enum.map(& &1.kind) |> Enum.uniq(),
        started_at: ~U[2026-11-18 03:17:00.000000Z],
        finished_at: ~U[2026-11-18 03:20:00.000000Z],
        artifacts: artifacts
      },
      actor: Backups.system()
    )
  end

  defp events(admin) do
    Security.list_instance_events!(%{type: :backup_downloaded}, actor: admin)
  end

  describe "what may be downloaded" do
    test "a dump of an in-app run: its path, size and kind, and nothing recorded", %{
      dir: dir,
      admin: admin
    } do
      {:ok, id} = DirId.local(dir)
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)], dir_id: id)

      assert {:ok, download} = Backups.check_download(run.id, file.name, admin)

      assert download == %{
               path: Path.join([dir, "db", file.name]),
               name: file.name,
               kind: :db,
               bytes: file.bytes,
               stamp: @stamp,
               dir_id: id
             }

      assert events(admin) == []
    end

    test "each part of a media set in order, and its checksum file", %{dir: dir, admin: admin} do
      files = for name <- Artifact.set_names(@stamp, 3), do: write!(dir, "media", name)
      sidecar = write!(dir, "media", Artifact.sidecar_name(:media, @stamp), "sums\n")
      run = app_run!([media_artifact(files)])

      for file <- files do
        assert {:ok, %{name: name, kind: :media, bytes: bytes}} =
                 Backups.check_download(run.id, file.name, admin)

        assert {name, bytes} == {file.name, file.bytes}
      end

      assert {:ok, %{name: name, bytes: 5}} = Backups.check_download(run.id, sidecar.name, admin)
      assert name == sidecar.name
    end

    test "an imported row with no directory id", %{dir: dir, admin: admin} do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = import_run!([db_artifact(file)])

      assert run.dir_id == nil
      assert {:ok, %{name: _, dir_id: nil}} = Backups.check_download(run.id, file.name, admin)
    end

    test "a failed run's files that passed the name checks", %{dir: dir, admin: admin} do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")

      run =
        %{stamp: @stamp, trigger: "test"}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.fail_run!(%{artifacts: [db_artifact(file)], error: "x"},
          actor: Backups.system()
        )

      assert {:ok, _} = Backups.check_download(run.id, file.name, admin)
    end
  end

  describe "names that are not one of the row's" do
    setup %{dir: dir} do
      outside =
        Path.join(Path.dirname(dir), "kiln_dl_outside_#{System.unique_integer([:positive])}")

      File.write!(outside, "outside")
      on_exit(fn -> File.rm(outside) end)

      db = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      # Present on disk, but not this row's: another stamp, and partials.
      write!(dir, "db", "kiln-db-#{@other_stamp}.dump")
      write!(dir, "db", "kiln-db-#{@stamp}.dump.partial")
      write!(dir, "db", "kiln-db-#{@stamp}.dump.48211-2.partial")
      write!(dir, "media", "kiln-media-#{@stamp}.part1.tar.gz")
      File.write!(Path.join(dir, "manifest.json"), "{}")

      %{run: app_run!([db_artifact(db)]), outside: outside}
    end

    test "every one is :not_found, from both actions, and nothing is recorded", %{
      run: run,
      admin: admin,
      outside: outside
    } do
      names = [
        "../../etc/passwd",
        "../db/kiln-db-#{@stamp}.dump",
        "/etc/passwd",
        outside,
        Path.basename(outside),
        "../" <> Path.basename(outside),
        "kiln-db-#{@stamp}.dump%2F..",
        "..%2Fkiln-db-#{@stamp}.dump",
        "kiln-db-#{@stamp}.dump\\..",
        "kiln-db-#{@stamp}.dump" <> <<0>>,
        String.duplicate("a", 256),
        " kiln-db-#{@stamp}.dump",
        "kiln-db-#{@stamp}.dump ",
        "",
        "kiln-db-#{@other_stamp}.dump",
        "kiln-db-#{@stamp}.dump.partial",
        "kiln-db-#{@stamp}.dump.48211-2.partial",
        "kiln-media-#{@stamp}.part1.tar.gz",
        "kiln-media-#{@stamp}.tar.gz",
        # A sidecar of a kind the run has no artifact of.
        Artifact.sidecar_name(:media, @stamp),
        Artifact.sidecar_name(:db, @other_stamp),
        "manifest.json",
        ".kiln-dir-id"
      ]

      for name <- names do
        assert {:error, :not_found} = Backups.check_download(run.id, name, admin),
               "#{inspect(name)} must be refused"

        assert {:error, :not_found} = Backups.download(run.id, name, admin),
               "#{inspect(name)} must be refused"
      end

      assert events(admin) == []
    end

    test "a file that isn't a string, and a run that doesn't exist", %{run: run, admin: admin} do
      for file <- [nil, 1, %{}] do
        assert {:error, :not_found} = Backups.check_download(run.id, file, admin)
      end

      name = "kiln-db-#{@stamp}.dump"
      assert {:error, :not_found} = Backups.check_download(Ash.UUID.generate(), name, admin)
      assert {:error, :not_found} = Backups.check_download("not-a-uuid", name, admin)
      assert {:error, :not_found} = Backups.check_download(nil, name, admin)
    end

    test "a part out of list order on the row", %{dir: dir, admin: admin} do
      stamp = "20261116-031700"
      [one, two] = for name <- Artifact.set_names(stamp, 2), do: write!(dir, "media", name)
      run = app_run!([%{media_artifact([two, one]) | name: "kiln-media-#{stamp}"}], stamp: stamp)

      for file <- [one, two] do
        assert {:error, :not_found} = Backups.check_download(run.id, file.name, admin)
      end
    end

    test "a row whose artifact names another stamp", %{dir: dir, admin: admin} do
      other = Path.join([dir, "db", "kiln-db-#{@other_stamp}.dump"])

      run =
        app_run!([db_artifact(%{name: Path.basename(other), bytes: 1, sha256: nil})],
          stamp: "20261116-031700"
        )

      assert {:error, :not_found} = Backups.check_download(run.id, Path.basename(other), admin)
    end
  end

  describe "what is on disk under the name" do
    test "a symlink or a directory is :not_regular", %{dir: dir, admin: admin} do
      target = Path.join(dir, "target")
      File.write!(target, "data")
      name = "kiln-db-#{@stamp}.dump"
      File.ln_s!(target, Path.join([dir, "db", name]))
      run = app_run!([%{kind: :db, name: name, bytes: 4, verified: true}])

      assert {:error, :not_regular} = Backups.check_download(run.id, name, admin)
      assert {:error, :not_regular} = Backups.download(run.id, name, admin)

      media = "kiln-media-#{@other_stamp}.tar.gz"
      File.mkdir_p!(Path.join([dir, "media", media]))
      dir_run = import_run!([%{kind: :media, name: media, bytes: 1}], @other_stamp)

      assert {:error, :not_regular} = Backups.check_download(dir_run.id, media, admin)

      assert events(admin) == []
    end

    test "a file that isn't here is :missing", %{admin: admin} do
      name = "kiln-db-#{@stamp}.dump"
      run = app_run!([%{kind: :db, name: name, bytes: 4, verified: true}])

      assert {:error, :missing} = Backups.check_download(run.id, name, admin)
    end

    test "a file the server can't read is :unreadable, and nothing is recorded", %{
      dir: dir,
      admin: admin
    } do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      path = Path.join([dir, "db", file.name])
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)

      # Root reads anything; the refusal can't be shown there.
      if match?({:error, :eacces}, File.read(path)) do
        run = app_run!([db_artifact(file)])

        assert {:error, :unreadable} = Backups.check_download(run.id, file.name, admin)
        assert {:error, :unreadable} = Backups.download(run.id, file.name, admin)
        assert events(admin) == []
      end
    end
  end

  describe "pruned here" do
    test "a file marked pruned is refused though a file of its name is still here", %{
      dir: dir,
      admin: admin
    } do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      write!(dir, "db", Artifact.sidecar_name(:db, @stamp), "sums\n")

      run =
        app_run!([db_artifact(file, %{"local" => %{"status" => "pruned", "at" => "2026-01-01"}})])

      assert {:error, :pruned} = Backups.check_download(run.id, file.name, admin)
      assert {:error, :pruned} = Backups.download(run.id, file.name, admin)

      # Its artifact's every file is pruned: so is its checksum file.
      assert {:error, :pruned} =
               Backups.check_download(run.id, Artifact.sidecar_name(:db, @stamp), admin)

      assert events(admin) == []
    end

    test "one part pruned: that part is refused, the others and the sidecar are not", %{
      dir: dir,
      admin: admin
    } do
      files = for name <- Artifact.set_names(@stamp, 3), do: write!(dir, "media", name)
      write!(dir, "media", Artifact.sidecar_name(:media, @stamp), "sums\n")

      run =
        app_run!([
          media_artifact(files, part_destinations: %{2 => %{"local" => %{"status" => "pruned"}}})
        ])

      [one, two, three] = files
      assert {:error, :pruned} = Backups.check_download(run.id, two.name, admin)
      assert {:ok, _} = Backups.check_download(run.id, one.name, admin)
      assert {:ok, _} = Backups.check_download(run.id, three.name, admin)

      assert {:ok, _} =
               Backups.check_download(run.id, Artifact.sidecar_name(:media, @stamp), admin)
    end

    test "a part with no local marker of its own falls back to the artifact's", %{
      dir: dir,
      admin: admin
    } do
      files = for name <- Artifact.set_names(@stamp, 2), do: write!(dir, "media", name)

      run =
        app_run!([
          media_artifact(files,
            destinations: %{"local" => %{"status" => "pruned"}},
            part_destinations: %{1 => %{"dest:x" => %{"status" => "ok"}}}
          )
        ])

      for file <- files do
        assert {:error, :pruned} = Backups.check_download(run.id, file.name, admin)
      end
    end
  end

  describe "in progress" do
    test "a running run is refused", %{dir: dir, admin: admin} do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([], running?: true)

      assert {:error, :in_progress} = Backups.check_download(run.id, file.name, admin)
    end

    test "a run whose stamp the backup lock holds is refused", %{dir: dir, admin: admin} do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)])

      seam(:held_stamp, fn -> {:ok, @stamp} end)
      assert {:error, :in_progress} = Backups.check_download(run.id, file.name, admin)

      seam(:held_stamp, fn -> {:ok, @other_stamp} end)
      assert {:ok, _} = Backups.check_download(run.id, file.name, admin)
    end

    test "a lock that can't be read refuses", %{dir: dir, admin: admin} do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)])

      seam(:held_stamp, fn -> {:error, :boom} end)

      assert {:error, {:lock_unreadable, :boom}} =
               Backups.check_download(run.id, file.name, admin)
    end
  end

  describe "the backup directory a run is pinned to (#2539)" do
    test "another directory's run is refused, naming it", %{dir: dir, admin: admin} do
      {:ok, _here} = DirId.local(dir)
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      elsewhere = Ash.UUID.generate()
      run = app_run!([db_artifact(file)], dir_id: elsewhere)

      assert {:error, {:other_directory, ^elsewhere}} =
               Backups.check_download(run.id, file.name, admin)
    end

    test "a directory id that can't be read refuses a pinned run", %{dir: dir, admin: admin} do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)], dir_id: Ash.UUID.generate())

      assert {:error, {:dir_id_unreadable, :enoent}} =
               Backups.check_download(run.id, file.name, admin)

      File.write!(DirId.path(dir), "not an id")

      assert {:error, {:dir_id_unreadable, :malformed_dir_id}} =
               Backups.check_download(run.id, file.name, admin)
    end
  end

  describe "the audit (download/4)" do
    test "writes one backup_downloaded event with the request, and returns the path", %{
      dir: dir,
      admin: admin
    } do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)])

      context =
        Recorder.context(%{peer_data: %{address: {203, 0, 113, 7}}, user_agent: "Test/1.0"})

      assert {:ok, %{path: path}} = Backups.download(run.id, file.name, admin, context)
      assert path == Path.join([dir, "db", file.name])

      assert [event] = events(admin)

      assert %{
               type: :backup_downloaded,
               actor_id: actor_id,
               target_type: "backup_run",
               target_id: target_id,
               ip: "203.0.113.7",
               user_agent: "Test/1.0"
             } = event

      assert actor_id == admin.id
      assert target_id == run.id

      assert event.metadata == %{
               "stamp" => @stamp,
               "file" => file.name,
               "kind" => "db",
               "bytes" => file.bytes,
               "node" => to_string(node())
             }
    end

    test "nothing comes back when the event isn't written: :audit_failed", %{
      dir: dir,
      admin: admin
    } do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)])

      for answer <- [{:error, :boom}, :skipped] do
        seam(:recorder, fn _type, _opts -> answer end)
        assert {:error, :audit_failed} = Backups.download(run.id, file.name, admin)
      end

      assert events(admin) == []
    end

    test "the event is the last check: a refused download calls no recorder", %{
      dir: dir,
      admin: admin
    } do
      test = self()

      seam(:recorder, fn type, opts ->
        send(test, {:recorded, type, opts})
        {:ok, :event}
      end)

      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file, %{"local" => %{"status" => "pruned"}})])

      assert {:error, :pruned} = Backups.download(run.id, file.name, admin)
      refute_received {:recorded, _, _}

      assert {:error, :not_found} = Backups.download(run.id, "../x", admin)
      refute_received {:recorded, _, _}

      # The check never records; the download does, once.
      other = write!(dir, "db", "kiln-db-#{@other_stamp}.dump")
      run2 = import_run!([db_artifact(other)], @other_stamp)

      assert {:ok, _} = Backups.check_download(run2.id, "kiln-db-#{@other_stamp}.dump", admin)
      refute_received {:recorded, _, _}

      assert {:ok, _} = Backups.download(run2.id, "kiln-db-#{@other_stamp}.dump", admin)
      assert_received {:recorded, :backup_downloaded, opts}
      assert opts[:scope] == :instance
      assert opts[:user].id == admin.id
    end
  end

  describe "who may" do
    test "only a platform admin: everyone else is :forbidden, and nothing is recorded", %{
      dir: dir,
      admin: admin
    } do
      file = write!(dir, "db", "kiln-db-#{@stamp}.dump")
      run = app_run!([db_artifact(file)])

      org_admin = user(:viewer)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        organization_id: KilnCMS.Accounts.default_org_id(),
        user_id: org_admin.id,
        role: :admin
      })

      expired =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      for actor <- [
            user(:editor),
            user(:viewer),
            org_admin,
            expired,
            nil,
            Backups.system(),
            KilnCMS.SystemActor.new(:security)
          ] do
        assert {:error, :forbidden} = Backups.check_download(run.id, file.name, actor)
        assert {:error, :forbidden} = Backups.download(run.id, file.name, actor)
      end

      assert events(admin) == []

      live =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:ok, _} = Backups.check_download(run.id, file.name, live)
    end
  end

  describe "origin_refusal/3 (pure)" do
    test "with no console host: one organization or none is allowed, more is refused" do
      assert Download.origin_refusal(nil, 0, :single) == nil
      assert Download.origin_refusal(nil, 1, :single) == nil
      assert Download.origin_refusal(nil, 2, :single) == :console_shares_origin
      assert Download.origin_refusal(nil, 50, :multi) == :console_shares_origin
    end

    test "fails closed on an org count or a verdict that can't be told" do
      assert Download.origin_refusal(nil, :unknown, :single) == :console_shares_origin
      assert Download.origin_refusal(nil, 1, :unknown) == :console_shares_origin
      assert Download.origin_refusal(nil, 1, :multi) == :console_shares_origin
    end

    test "a console host of its own allows any count" do
      for count <- [0, 1, 2, 50, :unknown], verdict <- [:single, :multi, :unknown] do
        assert Download.origin_refusal("console.example.test", count, verdict) == nil
      end
    end
  end

  test "only :app and :imported runs are served" do
    assert Download.served_origin?(:app)
    assert Download.served_origin?(:imported)

    for origin <- [:found, :foreign, nil, "app"] do
      refute Download.served_origin?(origin)
    end
  end
end
