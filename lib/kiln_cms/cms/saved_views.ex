defmodule KilnCMS.CMS.SavedViews do
  @moduledoc """
  Erasure's step for saved views (#2514): an erased account's private views
  are deleted. A shared view is an admin's published filter the team uses, so
  it stays, as authored content does; its `owner_id` points at the
  tombstone, which names nobody.

  `KilnCMS.Accounts.Changes.AnonymizeUser` calls it over every org, and
  `KilnCMS.Accounts.ErasureBackfill` over the orgs where an account erased
  before #2514 still has private views.

  One statement per org: saved views are tenant-scoped under strict tenancy
  and have no tenant-bypassing action, and adding one only for this would
  widen the resource.
  """

  require Ash.Query
  require Logger

  @doc """
  Delete `user_id`'s private saved views in each of `org_ids`.

  Inside a transaction (an erasure) the first failure raises and rolls it
  back. Outside one (the backfill) each org stands alone: every org is tried,
  each failure is logged with its org, and it raises at the end if any failed.
  """
  @spec forget_private_views(Ash.UUID.t(), [Ash.UUID.t()]) :: :ok
  def forget_private_views(user_id, org_ids) when is_binary(user_id) and is_list(org_ids) do
    if KilnCMS.Repo.in_transaction?(),
      do: Enum.each(org_ids, &forget_in_org!(user_id, &1)),
      else: forget_everywhere(user_id, org_ids)
  end

  defp forget_everywhere(user_id, org_ids) do
    failed =
      Enum.reject(org_ids, fn org_id ->
        try do
          forget_in_org!(user_id, org_id)
        rescue
          _error -> false
        end
      end)

    if failed != [] do
      raise "saved view forget_private_views failed for orgs: #{Enum.join(failed, ", ")}"
    end

    :ok
  end

  # Logs a failure with the org it happened in, then re-raises it unchanged,
  # as `KilnCMS.Newsletter.forget_member/2` does: inside a transaction a failed
  # bulk write is a rollback throw that must keep travelling up.
  defp forget_in_org!(user_id, org_id) do
    # authorize?: false — erasure is authorized once, as `User.:anonymize` (or
    # the staging scrub), and the backfill only reaches accounts already
    # erased. The person being erased owns these rows, so no admin actor would
    # be admitted to them, and the filter pins every row to this user's id.
    KilnCMS.CMS.SavedView
    |> Ash.Query.filter(owner_id == ^user_id and shared == false)
    |> Ash.bulk_destroy!(:destroy, %{},
      tenant: org_id,
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )

    true
  catch
    kind, reason ->
      Logger.error(
        "saved view forget_private_views failed for org #{org_id}: " <>
          Exception.format_banner(kind, reason)
      )

      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
