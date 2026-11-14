defmodule KilnCMS.CMS.Changes.SecondFactorPolicyChanged do
  @moduledoc """
  After a `KilnCMS.CMS.SiteSecondFactorPolicy` write commits (#2247): drops the
  cached policy on every node, then tells the site's open pages on
  `KilnCMS.Accounts.TwoFactorRequirement.topic/1` with
  `{:second_factor_policy_changed, policy}`, and drops the open connections
  of every account the new policy holds at once
  (`KilnCMS.Accounts.SecondFactorEviction`, in a supervised task).

  After COMMIT, through `KilnCMS.AfterCommit`: a page that re-read before the
  write committed would find the old policy. A write that failed or rolled
  back announces nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.TwoFactorRequirement

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &announce/2)
  end

  defp announce(_changeset, {:ok, record} = result) do
    org_id = record.org_id
    policy = TwoFactorRequirement.from_row(record)

    KilnCMS.AfterCommit.run(fn ->
      KilnCMS.Cache.bust_second_factor_policy(org_id)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        TwoFactorRequirement.topic(org_id),
        {:second_factor_policy_changed, policy}
      )

      KilnCMS.Accounts.SecondFactorEviction.dispatch(org_id, policy)
    end)

    result
  end

  defp announce(_changeset, other), do: other
end
