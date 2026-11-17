defmodule KilnCMS.Media.QuarantineReaper do
  @moduledoc """
  Removes quarantined `MediaItem`s whose deferred metadata strip never
  completed (#1122).

  `KilnCMS.Media.AVStripWorker` retries a transient strip failure and gives up
  after its attempts; a job that was never queued at all (an Oban insert
  failure at upload time), or a node that died mid-strip after the last
  attempt, leaves a row that is `quarantined: true` forever — invisible to
  readers, unservable, and a private blob nobody will ever promote. This
  sweeps them: any quarantined item older than `max_age_hours/0` has its row
  purged (the hard delete; a soft-deleted quarantined row would still be a
  private blob), then its private blob deleted.

  Row first, blob only on a successful purge (#2835), as the admin purge in
  `MediaLive` does: a purge that fails or is refused (the strip released the
  item after the scan read it) keeps the blob with its row. A quarantined
  item has no variants or derivatives to delete: derivation is enqueued only
  on release.

  Hourly by default (`config :kiln_cms, :media_quarantine_reaper_cron`,
  `KILN_MEDIA_QUARANTINE_REAPER_CRON`; `false` disables). The window is
  generous on purpose — an hour of retries with backoff is nowhere near it —
  because the failure it exists for is "stuck", not "slow", and reaping a
  strip that is still legitimately retrying would be the worse mistake.
  One cross-org read (`CMS.list_expired_quarantined_media`, a `multitenancy
  :bypass` action — a tenant-less read of the primary action is refused under
  strict tenancy), then each row is purged under its own tenant. Both run as
  `KilnCMS.Media.system/0` (#1659), which may purge an item only while it is
  quarantined, through `:purge_quarantined` (#2610).
  """
  use Oban.Worker, queue: :media, max_attempts: 1, unique: [period: 3_000]

  alias KilnCMS.{CMS, Media, Storage}

  require Logger

  @max_age_hours 24

  @doc "How old (in hours) a quarantined item must be before the reaper takes it."
  @spec max_age_hours() :: pos_integer()
  def max_age_hours,
    do: Application.get_env(:kiln_cms, :media_quarantine_max_age_hours, @max_age_hours)

  @impl Oban.Worker
  def perform(_job) do
    {:ok, run()}
  end

  @doc """
  One sweep. Returns the number of items removed. Public so a deployment that
  drives the schedule itself can call it, and for the test.
  """
  @spec run() :: non_neg_integer()
  def run do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_hours() * 3600, :second)

    # `authorize_with: :error`: a refused scan would filter to "nothing is
    # stuck", and the reaper would report a clean sweep for ever. It raises.
    cutoff
    |> CMS.list_expired_quarantined_media!(actor: Media.system(), authorize_with: :error)
    |> Enum.count(&reap/1)
  end

  # Public only so a test can hand it a struct the row has moved on from.
  @doc false
  @spec reap(struct()) :: boolean()
  def reap(item) do
    Logger.warning(
      "Reaping quarantined media #{item.id} (#{item.filename}): its metadata strip never " <>
        "completed within #{max_age_hours()}h. Re-upload the file."
    )

    # Taken before the purge, which is what decides whether it may go.
    key = item.storage_key

    case CMS.purge_quarantined_media_item(item, actor: Media.system(), tenant: item.org_id) do
      :ok ->
        delete_private(item, key)

      {:ok, _} ->
        delete_private(item, key)

      {:error, reason} ->
        Logger.error(
          "Could not purge quarantined media #{item.id}: #{inspect(reason)}; its private blob is kept."
        )

        false
    end
  end

  # The row is gone either way, so it counts. A failed delete leaves a private
  # blob with no row, which nothing sweeps; logged with the key.
  defp delete_private(item, key) do
    case Storage.delete_private(key, item) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Reaped media #{item.id} left its private blob #{key} behind: #{inspect(reason)}"
        )
    end

    true
  end
end
