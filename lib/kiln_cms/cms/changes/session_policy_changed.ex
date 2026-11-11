defmodule KilnCMS.CMS.Changes.SessionPolicyChanged do
  @moduledoc """
  After any `KilnCMS.CMS.SiteSessionPolicy` write commits (#2246): drops the
  cached policy on every node, then tells the site's open signed-in pages,
  which re-arm or cancel their idle timer and look again at the "sign out
  everyone" watermark (`KilnCMSWeb.IdleSession`).

  After COMMIT, through `KilnCMS.AfterCommit` — `sign_out_all` writes the
  watermark inside its own transaction, and a page that re-read before that
  committed would find the old one.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.IdleTimeout

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &announce/2)
  end

  defp announce(changeset, {:ok, record} = result) do
    org_id = record.org_id

    policy =
      if changeset.action_type == :destroy,
        do: IdleTimeout.off(),
        else: IdleTimeout.from_row(record)

    KilnCMS.AfterCommit.run(fn ->
      KilnCMS.Cache.bust_session_policy(org_id)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        IdleTimeout.topic(org_id),
        {:session_policy_changed, policy}
      )
    end)

    result
  end

  # A failed write changed nothing, so there is nothing to announce.
  defp announce(_changeset, other), do: other
end
