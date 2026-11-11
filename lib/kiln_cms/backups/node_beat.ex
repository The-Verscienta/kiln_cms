defmodule KilnCMS.Backups.NodeBeat do
  @moduledoc """
  One node's backup heartbeat (#2218): proof that the node running a backup
  step is still alive.

  Each node's `KilnCMS.Backups.Heartbeat` upserts its row every 30 seconds with
  the **database's** clock (`now()`), so nodes with drifting clocks still agree
  on how old a beat is. A step whose node has not beaten for a few minutes, or
  whose node has restarted (`boot_id` changed), loses the backup lock and its
  step is requeued.

  `node` is the Oban node name (`Oban.config().node`), the same name a job's
  `attempted_by` records, so it must be unique per node.

  System-only: the heartbeat and the lock's reclaim sweep read and write as
  `KilnCMS.Backups.system/0`. No person reads a beat.
  """
  use Ash.Resource,
    domain: KilnCMS.Backups,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "backup_node_beats"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # `beat_at` is the database's `now()`, in the INSERT (`atomic_set`) and in
    # the conflict's UPDATE (`atomic_update`): Ash evaluates `expr(now())` in
    # Elixir, with this node's clock, so it is a fragment; and an upsert field
    # set only by `atomic_set` is left out of the UPDATE, so a second beat would
    # not move it.
    create :beat do
      accept [:node, :boot_id, :dir_id]
      upsert? true
      upsert_fields [:boot_id, :dir_id]
      change atomic_set(:beat_at, expr(fragment("now()")))
      change atomic_update(:beat_at, expr(fragment("now()")))
    end

    # Beats of nodes gone for a day: a decommissioned node's row.
    destroy :prune do
      change filter(expr(beat_at < ago(1, :day)))
    end
  end

  policies do
    policy always() do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :backups}
    end
  end

  attributes do
    attribute :node, :string do
      primary_key? true
      allow_nil? false
      constraints max_length: KilnCMS.Limits.identifier()
      public? true
    end

    # This boot of the node (`KilnCMS.Backups.boot_id/0`); a different one
    # under the same node name means the node restarted.
    attribute :boot_id, :uuid do
      allow_nil? false
      public? true
    end

    # The node's BACKUP_DIR id (`<dir>/.kiln-dir-id`), nil when it has none.
    attribute :dir_id, :uuid, public?: true

    attribute :beat_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end
end
