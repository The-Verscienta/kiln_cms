defmodule KilnCMS.CMS.Changes.RecordSecondFactorPolicyChange do
  @moduledoc """
  The audit event of a write to a site's two-step sign-in requirement (#2247):
  `second_factor_policy_changed`, in the transaction, so the setting and its
  event commit together.

  Metadata: `required_for` and `grace_days` after the write,
  `previous_required_for` before it (`"off"` with no row), `change`
  (`"strengthened"`, `"weakened"` or `"unchanged"`, from
  `KilnCMS.CMS.Changes.StampSecondFactorRequirement`) and `via` — `"admin"` for
  a person's save, attributed to them, or `"console"` for the operator's
  `operator_override`, with no actor (the server did it).

  Declared through `KilnCMS.CMS.OrgSettings`' `audit:` option in place of the
  generic `org_setting_changed`, which could not say what was weakened, and on
  `operator_override` by hand. One event per write.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Changes.StampSecondFactorRequirement
  alias KilnCMS.Security.Changes.Record

  @impl true
  def change(changeset, _opts, context) do
    Record.change(
      changeset,
      [
        type: :second_factor_policy_changed,
        when: fn _record, changeset -> via(changeset) != nil end,
        user: fn _record, changeset -> person(changeset) end,
        target: fn record, _changeset -> {"site_second_factor_policy", Map.get(record, :id)} end,
        metadata: &metadata/2
      ],
      context
    )
  end

  defp person(changeset) do
    case changeset.context[:private][:actor] do
      %User{} = user -> user
      _other -> nil
    end
  end

  # A person's write, or the operator's override; any other system write is
  # not a decision anyone made and is not recorded.
  defp via(changeset) do
    cond do
      changeset.action.name == :operator_override -> "console"
      person(changeset) != nil -> "admin"
      true -> nil
    end
  end

  defp metadata(record, changeset) do
    previous = changeset.context[StampSecondFactorRequirement.previous_key()]

    %{
      "required_for" => to_string(record.required_for),
      "grace_days" => record.grace_days,
      "previous_required_for" => to_string((previous && previous.required_for) || :off),
      "change" => changeset.context[StampSecondFactorRequirement.change_key()] || "unchanged",
      "via" => via(changeset)
    }
  end
end
