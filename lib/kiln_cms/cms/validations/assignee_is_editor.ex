defmodule KilnCMS.CMS.Validations.AssigneeIsEditor do
  @moduledoc """
  A task's assignee must hold at least editor privilege on the task's org
  (#501 security review; per-org since #419).

  `assignee_id` is client-supplied (the editor's assign form/`task_draft`
  event). Without this check, an editor could route a task — content title,
  free-text note, and an email notification — to *any* registered user id,
  including a `:viewer` account or one with no relationship to editorial
  work at all: a way to exfiltrate content to an arbitrary account, and an
  unbounded mail-bombing vector against any user id.

  "Privilege" is `KilnCMS.Accounts.Scoping.effective_tier/2` on the org the
  task is written under — the changeset's tenant, or the default org when
  tenant-less (which is also the org a tenant-less task is stamped with). That
  is the resolution every content policy uses, and the one
  `Scoping.users_with_tier/2` inverts for the editor's assignee picker, so the
  picker never offers someone this then refuses. It is also why a global
  `User.role` is not enough: an org's editors are usually members whose tier
  comes from their `OrgMembership`, and a global editor with no standing on
  this org resolves to `:none` here — a task routed to them would carry this
  site's content to someone who cannot open it.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.User

  @impl true
  def validate(changeset, _opts, _context) do
    assignee_id = Ash.Changeset.get_attribute(changeset, :assignee_id)

    cond do
      is_nil(assignee_id) ->
        :ok

      editor_or_admin?(assignee_id, changeset) ->
        :ok

      true ->
        {:error, field: :assignee_id, message: "must be an editor or admin"}
    end
  end

  defp editor_or_admin?(user_id, changeset) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, user} -> Scoping.effective_tier(user, changeset) in [:editor, :admin]
      _ -> false
    end
  end
end
