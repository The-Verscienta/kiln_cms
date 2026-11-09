defmodule KilnCMS.Accounts.Changes.EraseRejectedAccount do
  @moduledoc """
  Erases a rejected applicant's account in the rejection's transaction, when
  the site asked for it and the account is nothing but that application
  (#2514), on `OrgMembership.:reject_registration`.

  An erasure happens only when every one of these holds; otherwise the
  account is kept, as it always was:

    * the caller asked (`erase: true`). The console passes it only when the
      confirmation it showed said the account would be erased, so an admin is
      never surprised by an erasure they were not warned of;
    * the site's `SiteRegistration.rejected_accounts` is `:erase_unconfirmed`,
      read before the transaction opens. A setting that cannot be read means
      keep: erasure cannot be undone, so it needs the site's known consent;
    * the actor is a **standing** admin of the row's site
      (`Registrations.Erasure.standing_admin?/2`). A temporary admin may
      reject, and the account is kept;
    * `Registrations.Erasure.check/1` passes, under the lock: the address was
      never confirmed, the registration created the account, and nothing else
      hangs off it.

  ## The order of things

  Declared first on the action, so its hooks run in this order:

    1. `before_transaction`: the three conditions that need no lock. When any
       fails nothing below happens, not even the lock (an ordinary rejection
       takes the membership row only);
    2. `before_action`, ahead of `get_and_lock_for_update()`: the account's
       row `FOR UPDATE` (`AccountLock.exclusive/1`), so the lock order is the
       account first, then the membership, as on every other path;
    3. the rejection itself (`DecideRegistration`, which refuses a row that is
       no longer `:pending`) and its write;
    4. `after_action`: `Erasure.check/1`, then `Accounts.anonymize_user/2` as
       `SystemActor.new(:registrations)`, with the membership and its
       `decided_at` in the context for `GuardRegistrationErasure`. A failed
       erasure returns its error, and the whole rejection rolls back. The
       outcome (`:erased` or `:kept`) goes on the returned record's metadata
       as `:registration_outcome`, which `RecordRegistration` (declared after,
       so it runs after) records;
    5. `after_transaction`, on success: whatever the erasure deferred
       (`AfterCommit.capture/1` around it) is replayed, so the rejection is
       self-contained whether or not a caller wraps it in
       `AfterCommit.deferring/1`.

  No decision mail is involved: an unconfirmed applicant is never mailed.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountLock
  alias KilnCMS.Accounts.RegistrationPolicy
  alias KilnCMS.Accounts.Registrations.Erasure
  alias KilnCMS.AfterCommit
  alias KilnCMS.SystemActor

  @context_key :registration_erasure

  @doc "The changeset context key the erasure hands `GuardRegistrationErasure`."
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_argument(changeset, :erase) == true do
      changeset
      |> Ash.Changeset.before_transaction(&decide(&1, context.actor))
      |> Ash.Changeset.before_action(&lock/1)
      |> Ash.Changeset.after_action(&erase/2)
      |> Ash.Changeset.after_transaction(&replay/2)
    else
      Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, kept(record)} end)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "may erase the account in the rejection's transaction"}

  # Whether this rejection will try to erase, decided once, before the
  # transaction: the setting is read on the caller's process, and a failed
  # read must not abort a transaction it is inside of.
  defp decide(changeset, actor) do
    org_id = changeset.data.organization_id

    erase? =
      Erasure.standing_admin?(actor, org_id) and erase_setting?(org_id)

    Ash.Changeset.set_context(changeset, %{erase_rejected_account?: erase?})
  end

  defp erase_setting?(org_id) do
    case RegistrationPolicy.settings(org_id) do
      {:ok, %{rejected_accounts: :erase_unconfirmed}} ->
        true

      {:ok, _keep} ->
        false

      {:error, :unavailable} ->
        Logger.warning(
          "registration rejected on org #{org_id} without erasure: " <>
            "the site's registration settings could not be read, so the account is kept"
        )

        false
    end
  end

  defp erase?(changeset), do: changeset.context[:erase_rejected_account?] == true

  defp lock(changeset) do
    if erase?(changeset) do
      # The account's state is re-read by `Erasure.check/1` after the write;
      # this is the lock it reads under.
      _state = AccountLock.exclusive(changeset.data.user_id)
    end

    changeset
  end

  defp erase(changeset, membership) do
    with true <- erase?(changeset),
         :erasable <- Erasure.check(membership) do
      anonymize(membership)
    else
      false ->
        {:ok, kept(membership)}

      {:keep, _reason} ->
        {:ok, kept(membership)}
    end
  end

  defp anonymize(membership) do
    {result, effects} =
      AfterCommit.capture(fn ->
        # authorize?: false — reads the one account being erased, to hand it
        # to `:anonymize`; that action is authorized as the registrations
        # system actor and guarded by `GuardRegistrationErasure`
        with {:ok, user} <- Accounts.get_user(membership.user_id, authorize?: false) do
          Accounts.anonymize_user(user,
            actor: SystemActor.new(:registrations),
            context:
              Map.put(AfterCommit.context(), @context_key, %{
                membership_id: membership.id,
                organization_id: membership.organization_id,
                decided_at: membership.decided_at
              })
          )
        end
      end)

    case result do
      {:ok, _erased} ->
        {:ok,
         membership
         |> Ash.Resource.put_metadata(:registration_outcome, :erased)
         |> Ash.Resource.put_metadata(:erasure_effects, effects)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp kept(membership), do: Ash.Resource.put_metadata(membership, :registration_outcome, :kept)

  defp replay(_changeset, {:ok, membership}) do
    AfterCommit.replay(membership.__metadata__[:erasure_effects] || [])

    {:ok, %{membership | __metadata__: Map.delete(membership.__metadata__, :erasure_effects)}}
  end

  defp replay(_changeset, result), do: result
end
