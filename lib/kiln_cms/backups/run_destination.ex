defmodule KilnCMS.Backups.RunDestination do
  @moduledoc """
  How one off-site destination fared in a backup run (#2220), embedded in
  `KilnCMS.Backups.Run`'s `destinations`.

  `key` is the destination's key, as in an artifact's `destinations` map
  (`KilnCMS.Backups.Artifact`): `"rclone:<redacted remote>"` for
  `BACKUP_RCLONE_REMOTE`, `"dest:<uuid>"` for a stored
  `KilnCMS.Backups.DestinationConfig`. `kind` is the adapter's kind and
  `label` a redacted snapshot of the destination's name, kept so History can
  still name a destination after its row is deleted.

  `status` is `pending` until the destination's step settles it, then `ok`,
  `failed` or `skipped`. It is a `KilnCMS.Types.KnownAtom`, so a status a newer
  release adds loads as a `KilnCMS.Types.UnknownAtom` on this one instead of
  failing the read of the whole history.

  ## Destinations that couldn't be read

  When the stored destinations can't be read for a run, the run records one
  entry with the key `unreadable_key/0` (`"unreadable"`) and status `failed`,
  rather than a status of its own: nothing a status could add, and a status an
  older release lacks loads as unknown anyway. `KilnCMS.Backups.Recorder`'s
  `offsite_outcome/1` never counts such a run as complete.

  `files_ok` and `files_total` count the files sent, `pruned` the units
  retention deleted on the destination. `permanent` is true on a `failed`
  entry the adapter failed at once, with an error it says no retry fixes
  (`KilnCMS.Backups.Destination.permanent?/1`, #2223), so History can say
  so (#3084); `nil` on an entry recorded before it existed. `error` and `label` are redacted and
  capped by `KilnCMS.Backups.Run.Changes.Normalize`, not by constraints here: a
  constraint would refuse the whole Run write while it is cast, before any
  change runs (as `KilnCMS.Backups.LogEntry` explains).
  """
  use Ash.Resource, data_layer: :embedded

  @statuses [:pending, :ok, :failed, :skipped]
  @unreadable "unreadable"
  @fields [
    :key,
    :kind,
    :label,
    :status,
    :error,
    :at,
    :files_ok,
    :files_total,
    :pruned,
    :permanent
  ]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @fields
    end

    update :update do
      primary? true
      accept @fields
    end
  end

  attributes do
    # Not length-capped: it must equal the artifacts' key for the same
    # destination, and those keys aren't capped either.
    attribute :key, :string, allow_nil?: false, public?: true

    attribute :kind, :string, public?: true

    attribute :label, :string, public?: true

    attribute :status, KilnCMS.Types.KnownAtom do
      allow_nil? false
      default :pending
      constraints one_of: @statuses
      public? true
    end

    attribute :error, :string, public?: true

    attribute :permanent, :boolean, public?: true

    attribute :at, :utc_datetime_usec, public?: true

    attribute :files_ok, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :files_total, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :pruned, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end
  end

  @doc "Every status a destination may record."
  def statuses, do: @statuses

  @doc """
  The key of the entry a run records when its stored destinations couldn't be
  read (see the moduledoc).
  """
  def unreadable_key, do: @unreadable
end
