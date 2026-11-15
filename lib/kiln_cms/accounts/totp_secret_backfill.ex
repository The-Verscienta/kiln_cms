defmodule KilnCMS.Accounts.TotpSecretBackfill do
  @moduledoc """
  Moves every TOTP secret still stored in plaintext into its encrypted column.

  The expand step of expand/contract: this release added
  `users.totp_secret_encrypted` and `users.totp_pending_secret_encrypted`,
  writes only those, and clears the plaintext `users.totp_secret` and
  `users.totp_pending_secret` on every write. A row nobody has written since
  the upgrade still has its secret in plaintext, and still works, because
  `KilnCMS.Accounts.TotpSecrets` reads the plaintext first. This pass empties
  those columns, so a dump or backup taken afterwards carries no working
  authenticator seed. A later release drops them.

  ## What it does to a row

    * A plaintext secret (live or staged) is encrypted into its column, and the
      plaintext set to `NULL`, in one `UPDATE`.
    * An encrypted live secret with no plaintext one, on an account whose
      factor is off (`totp_confirmed_at IS NULL`), is dropped. This release
      never leaves that state: it is a factor a node of the previous release
      disabled during a rolling deploy or after a rollback, which cleared only
      the column it knows.
    * On an erased account (`anonymized_at` set), every TOTP column is
      cleared, for the same reason.

  Nothing else. It goes to the table through Ecto rather than an Ash action, as
  `KilnCMS.Keys.Reencrypt` does: it changes how a value is stored, not what it
  is, so no change, notifier or `updated_at` should see it. Rows are taken
  `FOR UPDATE` in batches, so an enrolment on the same row waits for the batch
  instead of being overwritten from a stale read.

  ## When it runs

  `KilnCMS.Application` enqueues it on boot, ten minutes out, so a rolling
  deploy is normally over first: once it has run, a node of the previous
  release finds no secret in the column it reads, and its users can sign in
  only with a recovery code or a passkey. Deduplicated for a day at the database
  level; a second run finds nothing to do. `config :kiln_cms,
  :totp_secret_backfill_on_boot, false` turns the boot enqueue off (the test
  and e2e builds do); `run/0` runs it by hand:

      bin/kiln_cms rpc "KilnCMS.Accounts.TotpSecretBackfill.run()"

  ## Rolling back past this release

  The previous release reads only the plaintext columns. `revert/0` writes each
  encrypted secret back to its plaintext column, and leaves the encrypted copy
  where it is, so a cluster rolled back after the backfill keeps working:

      bin/kiln_cms rpc "KilnCMS.Accounts.TotpSecretBackfill.revert()"

  Run it on a node of this release, before switching the image.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 86_400,
      fields: [:worker],
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.Keys.Vault

  @batch 500

  @typedoc "What a run changed, by row count."
  @type result :: %{
          encrypted: non_neg_integer(),
          orphans_dropped: non_neg_integer(),
          erased_cleared: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = run()

    if Enum.any?(result, fn {_key, count} -> count > 0 end) do
      Logger.info("TOTP secret backfill: #{inspect(result)}")
    end

    :ok
  end

  @doc "Run the pass over every user row. See the moduledoc."
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo, KilnCMS.Repo)
    loop(repo, %{encrypted: 0, orphans_dropped: 0, erased_cleared: 0})
  end

  defp loop(repo, acc) do
    {:ok, batch} =
      repo.transaction(fn ->
        repo.all(
          from(u in "users",
            where:
              not is_nil(u.totp_secret) or not is_nil(u.totp_pending_secret) or
                (is_nil(u.totp_confirmed_at) and not is_nil(u.totp_secret_encrypted)) or
                (not is_nil(u.anonymized_at) and
                   (not is_nil(u.totp_secret_encrypted) or
                      not is_nil(u.totp_pending_secret_encrypted))),
            order_by: u.id,
            limit: @batch,
            lock: "FOR UPDATE",
            select: %{
              id: u.id,
              totp_secret: u.totp_secret,
              totp_pending_secret: u.totp_pending_secret,
              totp_confirmed_at: u.totp_confirmed_at,
              anonymized_at: u.anonymized_at
            }
          )
        )
        |> Enum.map(&fix(repo, &1))
      end)

    acc = Enum.reduce(batch, acc, fn outcome, acc -> Map.update!(acc, outcome, &(&1 + 1)) end)

    # Every row fixed stops matching the query, so a short batch is the last.
    if length(batch) < @batch, do: acc, else: loop(repo, acc)
  end

  defp fix(repo, %{anonymized_at: %{}} = row) do
    update(repo, row.id,
      totp_secret: nil,
      totp_pending_secret: nil,
      totp_secret_encrypted: nil,
      totp_pending_secret_encrypted: nil
    )

    :erased_cleared
  end

  defp fix(repo, %{totp_secret: nil, totp_pending_secret: nil} = row) do
    # Matched only by the orphan clause: an encrypted live secret, no factor.
    update(repo, row.id, totp_secret_encrypted: nil)
    :orphans_dropped
  end

  defp fix(repo, row) do
    set =
      [
        encrypt(row.totp_secret, :totp_secret, :totp_secret_encrypted),
        encrypt(row.totp_pending_secret, :totp_pending_secret, :totp_pending_secret_encrypted)
      ]
      |> List.flatten()

    update(repo, row.id, set)
    :encrypted
  end

  defp encrypt(nil, _plain, _encrypted), do: []
  defp encrypt(secret, plain, encrypted), do: [{encrypted, Vault.encrypt(secret)}, {plain, nil}]

  defp update(repo, id, set) do
    {1, _} = repo.update_all(from(u in "users", where: u.id == ^id), set: set)
    :ok
  end

  @doc """
  Copy every encrypted TOTP secret back to its plaintext column, for a rollback
  to a release that reads only those (see the moduledoc). Returns how many
  rows it wrote. A plaintext value already in place is kept, since it is the
  newer one. A row whose ciphertext does not decrypt is left alone and counted
  under `:unreadable`.
  """
  @spec revert(keyword()) :: %{restored: non_neg_integer(), unreadable: non_neg_integer()}
  def revert(opts \\ []) do
    repo = Keyword.get(opts, :repo, KilnCMS.Repo)

    {:ok, result} =
      repo.transaction(fn ->
        from(u in "users",
          where:
            not is_nil(u.totp_secret_encrypted) or not is_nil(u.totp_pending_secret_encrypted),
          lock: "FOR UPDATE",
          select: %{
            id: u.id,
            totp_secret: u.totp_secret,
            totp_pending_secret: u.totp_pending_secret,
            totp_secret_encrypted: u.totp_secret_encrypted,
            totp_pending_secret_encrypted: u.totp_pending_secret_encrypted
          }
        )
        |> repo.all()
        |> Enum.reduce(%{restored: 0, unreadable: 0}, fn row, acc ->
          outcome = restore(repo, row)
          Map.update!(acc, outcome, &(&1 + 1))
        end)
      end)

    result
  end

  # A plaintext value already there is kept: it is never older than the
  # ciphertext (see `KilnCMS.Accounts.TotpSecrets`).
  defp restore(repo, row) do
    with {:ok, live} <- decrypt(row.totp_secret_encrypted),
         {:ok, pending} <- decrypt(row.totp_pending_secret_encrypted) do
      update(repo, row.id,
        totp_secret: row.totp_secret || live,
        totp_pending_secret: row.totp_pending_secret || pending
      )

      :restored
    else
      {:error, :decrypt_failed} -> :unreadable
    end
  end

  defp decrypt(nil), do: {:ok, nil}
  defp decrypt(ciphertext), do: Vault.decrypt(ciphertext)

  @doc """
  Queue the pass ten minutes out, unless one is already queued or ran today.
  Never raises: a node must not fail to start because this could not be queued.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new(schedule_in: 600) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.warning("TOTP secret backfill not queued: #{inspect(reason)}")
    :ok
  end
end
