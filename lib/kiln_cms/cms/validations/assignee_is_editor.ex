defmodule KilnCMS.CMS.Validations.AssigneeIsEditor do
  @moduledoc """
  A task's assignee must hold at least editor privilege (#501 security
  review).

  `assignee_id` is client-supplied (the editor's assign form/`task_draft`
  event). Without this check, an editor could route a task — content title,
  free-text note, and an email notification — to *any* registered user id,
  including a `:viewer` account or one with no relationship to editorial
  work at all: a way to exfiltrate content to an arbitrary account, and an
  unbounded mail-bombing vector against any user id.

  Checked against `KilnCMS.Accounts.User.role` (global), not
  `KilnCMS.Accounts.OrgMembership` — the same source every other authz check
  in this codebase currently reads (see `OrgMembership`'s own moduledoc:
  membership rows mirror the per-org RBAC rewiring in progress, but aren't
  the enforced source yet, and nothing creates one automatically on
  registration — an `OrgMembership`-based check would reject freshly
  registered users who are otherwise legitimate editors, since only
  `TeamLive`'s explicit invite flow creates membership rows). Mirrors
  `KilnCMS.Notifications.dispatch/3`'s own `User |> Ash.Query.filter(role ==
  :admin)` recipient resolution — the established pattern for "which users
  count as staff" in this codebase today.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias KilnCMS.Accounts.User

  @impl true
  def validate(changeset, _opts, _context) do
    assignee_id = Ash.Changeset.get_attribute(changeset, :assignee_id)

    cond do
      is_nil(assignee_id) ->
        :ok

      editor_or_admin?(assignee_id) ->
        :ok

      true ->
        {:error, field: :assignee_id, message: "must be an editor or admin"}
    end
  end

  defp editor_or_admin?(user_id) do
    User
    |> Ash.Query.filter(id == ^user_id and role in [:editor, :admin])
    |> Ash.exists?(authorize?: false)
  end
end
