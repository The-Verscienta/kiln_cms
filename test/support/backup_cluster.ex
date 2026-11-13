defmodule KilnCMS.Test.BackupCluster do
  @moduledoc """
  Several backup nodes in one test (#2789): each "node" is a backup directory
  and a heartbeat node name, played in turn by the test process.

  `as_node/2` points the VM-wide `KilnCMS.Backups` `:dir` at a node's
  directory while a function runs, so a test that uses it must be
  `async: false`. `tick_as/2` runs that node's heartbeat tick, and
  `backdate_beat!/2` ages its beat on the database's clock. `cron_backup!/2`
  leaves what `scripts/backup.sh` leaves.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Heartbeat, Manifest}

  @doc "Run `fun` with `KilnCMS.Backups.dir/0` answering `dir`."
  @spec as_node(Path.t(), (-> result)) :: result when result: term()
  def as_node(dir, fun) do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, dir))

    try do
      fun.()
    after
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end
  end

  @doc """
  One heartbeat tick of the node with backup directory `dir`. `node` is a node
  name (a fresh heartbeat state) or a `Heartbeat` state from an earlier tick,
  so a test can follow what the heartbeat remembers. Returns the new state.
  """
  @spec tick_as(Path.t(), String.t() | Heartbeat.state()) :: Heartbeat.state()
  def tick_as(dir, node) when is_binary(node) do
    tick_as(dir, Heartbeat.new_state(node: node, boot_id: Ash.UUID.generate()))
  end

  def tick_as(dir, %{} = state), do: as_node(dir, fn -> Heartbeat.tick(state) end)

  @doc "Age `node`'s beat to `seconds` before the database's `now()`."
  @spec backdate_beat!(String.t(), non_neg_integer()) :: :ok
  def backdate_beat!(node, seconds) do
    %{num_rows: 1} =
      KilnCMS.Repo.query!(
        "UPDATE backup_node_beats SET beat_at = now() - make_interval(secs => $2) " <>
          "WHERE node = $1",
        [node, seconds]
      )

    :ok
  end

  @doc "The beat `node` last reported, or nil."
  @spec beat_of(String.t()) :: Ash.Resource.record() | nil
  def beat_of(node), do: Backups.get_node_beat!(node, actor: Backups.system())

  @doc """
  What `backup.sh` leaves in `dir`: a dump, a media archive and the manifest
  of the run (which lets the importer take brand-new files without a settle
  wait).
  """
  @spec cron_backup!(Path.t(), String.t()) :: :ok
  def cron_backup!(dir, stamp) do
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))
    File.write!(Path.join([dir, "db", "kiln-db-#{stamp}.dump"]), "dump")
    File.write!(Path.join([dir, "media", "kiln-media-#{stamp}.tar.gz"]), "tar")
    {:ok, at} = Artifact.parse_stamp(stamp)

    :ok =
      Manifest.write(
        dir,
        struct!(Manifest,
          trigger: "cron",
          ok: true,
          started_at: at,
          finished_at: DateTime.add(at, 60),
          artifacts: [
            %{kind: "db", path: "db/kiln-db-#{stamp}.dump", bytes: 4, verified: true},
            %{kind: "media", path: "media/kiln-media-#{stamp}.tar.gz", bytes: 3, verified: true}
          ]
        )
      )
  end

  @doc "The `.good` markers in `dir`, as `\"db/<name>\"`, sorted."
  @spec goods(Path.t()) :: [String.t()]
  def goods(dir) do
    for sub <- ["db", "media"],
        name <- Enum.sort(File.ls!(Path.join(dir, sub))),
        String.ends_with?(name, ".good"),
        do: "#{sub}/#{name}"
  end
end
