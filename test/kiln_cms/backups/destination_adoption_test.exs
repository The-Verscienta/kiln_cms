defmodule KilnCMS.Backups.DestinationAdoptionTest do
  @moduledoc """
  A destination's adopted backup directories (`DestinationConfig`
  `:adopt_directories`): what may be adopted, what each adoption is bound to,
  who may adopt, and what the audit log and the Destinations tab's list of
  other backup directories (`Backups.other_backup_directories/2`) see.

  `async: false`: the backup directory and the live-beats reader are set in
  the `KilnCMS.Backups` application env, which is VM-global.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.Test.BackupDestinations, only: [destination!: 0]
  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, DestinationConfig, DirId}
  alias KilnCMS.Security

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    original = Application.get_env(:kiln_cms, Backups, [])
    on_exit(fn -> Application.put_env(:kiln_cms, Backups, original) end)

    dir = Path.join(tmp_dir, "backups")
    {:ok, own} = DirId.local(dir)
    put_env(dir: dir)

    %{own: own, admin: platform_admin(), retired: Ecto.UUID.generate()}
  end

  defp put_env(pairs) do
    Application.put_env(
      :kiln_cms,
      Backups,
      Keyword.merge(Application.get_env(:kiln_cms, Backups, []), pairs)
    )
  end

  # Another node, alive, with its own backup directory `dir_id`.
  defp live_node(dir_id) do
    put_env(live_beats_reader: fn _within_s -> {:ok, [%{dir_id: dir_id, last_dir_id: nil}]} end)
  end

  defp adopt(row, args, actor), do: Backups.adopt_backup_directories(row, args, actor: actor)

  defp events(type) do
    Security.list_instance_events!(actor: platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  defp messages(%{errors: errors}), do: Enum.map_join(errors, "\n", &Exception.message/1)

  describe "adopt_directories" do
    test "binds an adoption to every backup directory in use now, this node's included", %{
      own: own,
      admin: admin,
      retired: retired
    } do
      peer = Ecto.UUID.generate()
      live_node(peer)
      row = destination!()

      assert {:ok, %DestinationConfig{adoptions: [adoption]} = adopted} =
               adopt(row, %{adopt: [retired]}, admin)

      assert adoption["dir_id"] == retired
      assert Enum.sort(adoption["adopted_by"]) == Enum.sort([own, peer])
      assert {:ok, _at, 0} = DateTime.from_iso8601(adoption["adopted_at"])

      # Not an edit: an open edit form isn't made stale.
      assert adopted.updated_at == row.updated_at

      # Read back as stored.
      assert [%{"dir_id" => ^retired}] =
               Backups.get_backup_destination!(row.id, actor: admin).adoptions
    end

    test "an id in capitals or with spaces is stored lowercase; one that isn't an id is refused",
         %{admin: admin, retired: retired} do
      row = destination!()

      assert {:ok, %{adoptions: [%{"dir_id" => ^retired}]}} =
               adopt(row, %{adopt: ["  " <> String.upcase(retired) <> " "]}, admin)

      for bad <- ["not-an-id", "../x", String.duplicate("a", 36)] do
        assert {:error, %Ash.Error.Invalid{} = error} = adopt(row, %{adopt: [bad]}, admin)
        assert messages(error) =~ "is not a backup directory id"
      end

      # A blank one is cast to nil, and refused as that.
      assert {:error, %Ash.Error.Invalid{}} = adopt(row, %{adopt: [""]}, admin)

      assert [%{"dir_id" => ^retired}] =
               Backups.get_backup_destination!(row.id, actor: admin).adoptions

      assert {:error, %Ash.Error.Invalid{}} = adopt(row, %{release: ["nope"]}, admin)
    end

    test "adopting again binds afresh, never twice; release removes it", %{
      own: own,
      admin: admin,
      retired: retired
    } do
      row = destination!()
      {:ok, row} = adopt(row, %{adopt: [retired, String.upcase(retired)]}, admin)
      assert [%{"adopted_by" => [^own]}] = row.adoptions

      peer = Ecto.UUID.generate()
      live_node(peer)
      {:ok, row} = adopt(row, %{adopt: [retired]}, admin)
      assert [%{"dir_id" => ^retired, "adopted_by" => by}] = row.adoptions
      assert Enum.sort(by) == Enum.sort([own, peer])

      assert {:ok, %{adoptions: []}} = adopt(row, %{release: [retired]}, admin)
    end

    test "a backup directory a running server reports is refused, this node's own included", %{
      own: own,
      admin: admin
    } do
      peer = Ecto.UUID.generate()
      live_node(peer)
      row = destination!()

      for id <- [peer, own] do
        assert {:error, %Ash.Error.Invalid{} = error} = adopt(row, %{adopt: [id]}, admin)
        assert messages(error) =~ "belongs to a running server"
      end

      assert Backups.get_backup_destination!(row.id, actor: admin).adoptions == []
    end

    test "refused when the running servers can't be read, or none reports a directory", %{
      tmp_dir: tmp_dir,
      admin: admin,
      retired: retired
    } do
      row = destination!()

      put_env(live_beats_reader: fn _within_s -> {:error, :connection_refused} end)
      assert {:error, %Ash.Error.Invalid{} = error} = adopt(row, %{adopt: [retired]}, admin)
      assert messages(error) =~ "couldn't tell which backup directories"

      put_env(live_beats_reader: fn _within_s -> {:ok, []} end, dir: Path.join(tmp_dir, "none"))
      assert {:error, %Ash.Error.Invalid{} = error} = adopt(row, %{adopt: [retired]}, admin)
      assert messages(error) =~ "no running server reports a backup directory"

      # Releasing needs neither.
      assert {:ok, _row} = adopt(row, %{release: [retired]}, admin)
    end

    test "at most #{DestinationConfig.max_adoptions()} directories", %{admin: admin} do
      row = destination!()
      max = DestinationConfig.max_adoptions()
      ids = for _ <- 1..max, do: Ecto.UUID.generate()

      assert {:ok, row} = adopt(row, %{adopt: ids}, admin)
      assert length(row.adoptions) == max

      assert {:error, %Ash.Error.Invalid{} = error} =
               adopt(row, %{adopt: [Ecto.UUID.generate()]}, admin)

      assert messages(error) =~ "at most #{max}"
    end

    test "only a platform admin may adopt; an org admin, an editor and the system actor are " <>
           "refused",
         %{admin: admin, retired: retired} do
      row = destination!()

      for actor <- [site_admin(), user(:editor), user(:viewer), Backups.system()] do
        assert {:error, %Ash.Error.Forbidden{}} = adopt(row, %{adopt: [retired]}, actor)
        refute Backups.can_adopt_backup_directories?(actor, row)
      end

      assert Backups.can_adopt_backup_directories?(admin, row)
      assert Backups.get_backup_destination!(row.id, actor: admin).adoptions == []
    end

    test "the edit form's action neither takes nor clears adoptions", %{
      admin: admin,
      retired: retired
    } do
      row = destination!()
      {:ok, row} = adopt(row, %{adopt: [retired]}, admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.update_backup_destination(row, %{adoptions: []}, actor: admin)

      assert {:ok, renamed} =
               Backups.update_backup_destination(row, %{name: "Renamed"}, actor: admin)

      assert [%{"dir_id" => ^retired}] = renamed.adoptions
    end

    test "is audited in the instance log, naming what was adopted and removed; a change of " <>
           "nothing isn't",
         %{admin: admin, retired: retired} do
      row = destination!()
      {:ok, row} = adopt(row, %{adopt: [retired]}, admin)
      {:ok, row} = adopt(row, %{release: [retired]}, admin)
      {:ok, _row} = adopt(row, %{release: [retired]}, admin)

      events = events(:backup_destination_adoptions_changed)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.actor_id == admin.id and &1.target_id == row.id))

      assert %{"adopted" => ^retired, "removed" => "none"} =
               Enum.find(events, &(&1.metadata["removed"] == "none")).metadata

      assert %{"adopted" => "none", "removed" => ^retired} =
               Enum.find(events, &(&1.metadata["adopted"] == "none")).metadata
    end
  end

  describe "DestinationConfig.owners/2" do
    test "this directory, and the adopted ones bound to it" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      x = Ecto.UUID.generate()
      y = Ecto.UUID.generate()

      adoptions = [
        %{"dir_id" => x, "adopted_by" => [a], "adopted_at" => "2026-11-19T00:00:00Z"},
        %{"dir_id" => y, "adopted_by" => [a, b], "adopted_at" => "2026-11-19T00:00:00Z"}
      ]

      assert DestinationConfig.owners(a, adoptions) == [a, x, y]
      # Adopted on A: none of it reaches B but what B was named in.
      assert DestinationConfig.owners(b, adoptions) == [b, y]
      # A database restored on another server: its directory is in none.
      assert DestinationConfig.owners(Ecto.UUID.generate(), adoptions) |> length() == 1
      assert DestinationConfig.owners(nil, adoptions) == []
      assert DestinationConfig.owners(a, nil) == [a]
    end
  end

  describe "other_backup_directories/2" do
    defp sent!(stamp, key, dir_id, started_at) do
      {:ok, artifact} =
        Artifact.from_manifest(%{kind: "db", path: "db/kiln-db-#{stamp}.dump", verified: true})

      Backups.start_run!(
        %{
          stamp: stamp,
          trigger: "manual",
          started_at: started_at,
          dir_id: dir_id,
          destinations: [%{key: key, status: :ok}]
        },
        actor: Backups.system()
      )
      |> Backups.finish_run!(%{artifacts: [artifact]}, actor: Backups.system())
    end

    test "the other directories whose in-app backups reached it, leaving out the ones in use",
         %{own: own, admin: admin, retired: retired} do
      row = destination!()
      key = DestinationConfig.key(row)
      peer = Ecto.UUID.generate()
      live_node(peer)

      sent!("20200101-000000", key, retired, ~U[2020-01-01 00:00:00Z])
      sent!("20200102-000000", key, retired, ~U[2020-01-02 00:00:00Z])
      sent!("20200103-000000", key, own, ~U[2020-01-03 00:00:00Z])
      sent!("20200104-000000", key, peer, ~U[2020-01-04 00:00:00Z])
      # Another destination's.
      sent!(
        "20200105-000000",
        "dest:" <> Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        ~U[2020-01-05 00:00:00Z]
      )

      assert {:ok, [%{dir_id: ^retired, count: 2, last_at: ~U[2020-01-02 00:00:00.000000Z]}]} =
               Backups.other_backup_directories(row, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.other_backup_directories(row, actor: site_admin())
    end
  end
end
