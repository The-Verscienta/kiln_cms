defmodule KilnCMS.Accounts.SecondFactorEviction do
  @moduledoc """
  Drops the open connections of the accounts a site's two-step sign-in policy
  holds the moment it is saved (#2247): a grace of 0 days, a shorter grace, or
  a newly covered tier whose accounts' grace has already run out.

  A held account's open console pages already hear the change
  (`KilnCMSWeb.SecondFactorGate` follows `TwoFactorRequirement.topic/1`), but
  its GraphQL and collaboration sockets do not: they re-check on a document or
  on a 30-second timer. `KilnCMS.Accounts.SessionEviction.evict/2` drops every
  socket the account has, on every node, and each reconnect meets the gate.

  Evicting is not holding: an account evicted here that is not held where it
  reconnects (another site, or one that enrolled meanwhile) is simply
  connected again.

  ## After the commit, off the request

  `dispatch/2` is called from `KilnCMS.CMS.Changes.SecondFactorPolicyChanged`
  once the write has committed, and runs the roster read and the broadcasts in
  a task under `KilnCMS.TaskSupervisor`: never inside the write's transaction,
  and never holding up the admin who saved. Under test (`:async_analytics`
  off) it runs inline, on the test's sandbox connection, as the other
  detached security writes do.
  """
  require Logger

  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.TwoFactorRequirement.Policy

  @doc """
  Evict, in the background, every account `policy` holds on `org_id` now.
  Always `:ok`; nothing to do when the policy is off.
  """
  @spec dispatch(Ash.UUID.t(), Policy.t()) :: :ok
  def dispatch(_org_id, %Policy{required_for: :off}), do: :ok

  def dispatch(org_id, %Policy{} = policy) when is_binary(org_id) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn -> evict_overdue(org_id, policy) end)
    else
      evict_overdue(org_id, policy)
    end

    :ok
  catch
    # `start_child/2` is a call: a restarting supervisor exits the caller,
    # which here is a write that has already committed.
    :exit, reason ->
      Logger.warning("Second-factor eviction not started: #{inspect(reason)}")
      :ok
  end

  @doc """
  Evict every account `policy` holds on `org_id` now, and return their ids.

  A failed roster read is logged and evicts nobody: the policy is saved, the
  pages that follow it redirect on their own, and the sockets meet the gate
  on their next document or re-check.
  """
  @spec evict_overdue(Ash.UUID.t(), Policy.t(), keyword()) :: [Ash.UUID.t()]
  def evict_overdue(org_id, %Policy{} = policy, opts \\ []) do
    ids = TwoFactorRequirement.overdue_user_ids(org_id, policy, opts)
    Enum.each(ids, &SessionEviction.evict(&1, :second_factor_required))
    ids
  rescue
    error ->
      Logger.warning(
        "Second-factor eviction skipped for site #{org_id}: #{Exception.message(error)}"
      )

      []
  end
end
