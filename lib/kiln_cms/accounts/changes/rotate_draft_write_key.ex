defmodule KilnCMS.Accounts.Changes.RotateDraftWriteKey do
  @moduledoc """
  The body of `ApiKey`'s `:rotate` action: build the successor of the
  `:draft_write` key the actor authenticated with, and retire that key in the
  same transaction.

  Everything the successor carries is copied from the presenting key — owner,
  name, scope (`:draft_write`, never anything else) and `rotatable_until` —
  and the action accepts no input, so there is nothing a caller can widen. The
  lifetime is the shorter of the configured `:draft_write_key_max_ttl_days`
  and what is left of `rotatable_until`: the chain ends on the date the admin
  chose at mint, however often it rotates.

  The presenting key is re-read **under a row lock** in `before_action` and
  revoked there. Two concurrent rotations of one key therefore serialize: the
  second finds the row revoked and fails, so a lineage never forks into two
  live keys. The sign-in that produced the actor ran before the lock, so this
  is also where a key revoked in between is caught.

  The owner's sockets are evicted after the commit (as `:revoke` does), so a
  bridge socket on the old key reconnects against the committed revocation.

  Each rotation is logged and emits `[:kiln_cms, :api_key, :rotated]`
  telemetry after commit. Reuse of a rotated-away key is handled by
  `KilnCMS.Accounts.ApiKeyReuse`, not here.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Checks.RotatableDraftWriteKey
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Validations.DraftWriteKey

  @impl true
  def change(changeset, _opts, context) do
    now = DateTime.utc_now()
    key = RotatableDraftWriteKey.presenting_key(context.actor)

    if key && RotatableDraftWriteKey.rotatable?(key, now) do
      changeset
      |> Ash.Changeset.force_change_attributes(%{
        user_id: key.user_id,
        name: key.name,
        access: :draft_write,
        rotatable_until: key.rotatable_until,
        lineage_id: key.lineage_id || key.id,
        rotated_from_id: key.id,
        expires_at: successor_expiry(key.rotatable_until, now)
      })
      |> Ash.Changeset.before_action(&retire(&1, key.id))
      |> Ash.Changeset.after_transaction(&report(&1, &2, key))
    else
      # Not a rotatable key. The action's policy refuses it (as Forbidden, which
      # an error added here would pre-empt as Invalid); with nothing set and no
      # `retire` hook, no successor could be built even if authorization were
      # skipped — the required owner, name and expiry are missing.
      changeset
    end
  end

  @doc """
  When a successor minted at `now` expires: `now` plus the draft-write TTL
  ceiling, but never after `rotatable_until`.
  """
  @spec successor_expiry(DateTime.t(), DateTime.t()) :: DateTime.t()
  def successor_expiry(rotatable_until, now) do
    ttl_end = DateTime.add(now, DraftWriteKey.max_ttl_days(), :day)
    if DateTime.compare(ttl_end, rotatable_until) == :gt, do: rotatable_until, else: ttl_end
  end

  defp retire(changeset, key_id) do
    # authorize?: false — the action's own policy has already authorized the
    # actor to rotate exactly this key; the admin-only read and revoke policies
    # are about operators, not about a key retiring itself.
    with {:ok, row} <-
           Accounts.get_api_key(key_id, authorize?: false, query: [lock: "FOR UPDATE"]),
         # authorize?: false — locking re-read of the key this action already authorized
         true <- RotatableDraftWriteKey.rotatable?(row, DateTime.utc_now()),
         # authorize?: false — the presenting key retiring itself inside its authorized rotation
         {:ok, _revoked} <-
           Accounts.retire_rotated_api_key(row,
             authorize?: false,
             actor: changeset.context[:private][:actor],
             context:
               Map.take(changeset.context, [
                 KilnCMS.Security.Recorder.context_key(),
                 KilnCMS.Security.Recorder.tenant_key()
               ])
           ) do
      changeset
    else
      _ ->
        Ash.Changeset.add_error(changeset,
          field: :rotated_from_id,
          message: "this key has been revoked, has expired, or can no longer rotate"
        )
    end
  end

  defp report(_changeset, {:ok, successor} = result, predecessor) do
    # The old key is now revoked and committed: drop the owner's sockets, as
    # `:revoke` does, so one held open on the old key re-authorizes and fails.
    SessionEviction.evict(predecessor.user_id, :api_key_revoked)

    Logger.info(
      "API key #{predecessor.id} (user #{predecessor.user_id}) rotated itself into " <>
        "#{successor.id}, expiring #{DateTime.to_iso8601(successor.expires_at)}; " <>
        "lineage #{successor.lineage_id}, rotatable until " <>
        DateTime.to_iso8601(successor.rotatable_until)
    )

    :telemetry.execute([:kiln_cms, :api_key, :rotated], %{count: 1}, %{
      key_id: predecessor.id,
      successor_id: successor.id,
      lineage_id: successor.lineage_id,
      user_id: successor.user_id
    })

    result
  end

  defp report(_changeset, result, _predecessor), do: result
end
