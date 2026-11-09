defmodule KilnCMS.CMS.Changes.RecordAdminAllowlistChange do
  @moduledoc """
  The audit event of a person saving a site's admin allowlist (#2248):
  `admin_allowlist_changed`, in the transaction, attributed to the admin.

  It says how the list moved — `state` (`on` or `off` after the save), `count`
  (entries after), `added` and `removed` (how many) — and never which entries:
  an allowlist is often a list of the admins' own home and office addresses,
  and the log keeps what it records for its whole retention. The entries
  themselves are on the settings page.

  Declared through `KilnCMS.CMS.OrgSettings`' `audit:` option in place of the
  generic `org_setting_changed`, so a save is still exactly one event. A system
  write is not a person's decision and is not recorded here; the operator's
  override records its own event (`OperatorOverrideAdminAllowlist`).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Changes.Record

  @previous :admin_allowlist_previous

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&capture_previous/1)
    |> Record.change(
      [
        type: :admin_allowlist_changed,
        when: fn _record, changeset -> match?(%User{}, changeset.context[:private][:actor]) end,
        target: fn record, _changeset -> {"site_admin_allowlist", Map.get(record, :id)} end,
        metadata: &metadata/2
      ],
      context
    )
  end

  # The list before this write, read in the transaction. An upsert `:save` lands
  # on the existing row without loading it, so `changeset.data` cannot say.
  # A read that fails fails the save: the event must not guess.
  defp capture_previous(changeset) do
    case KilnCMS.CMS.list_site_admin_allowlist(
           tenant: changeset.tenant,
           actor: KilnCMS.SystemActor.new(:admin_allowlist),
           authorize_with: :error
         ) do
      {:ok, rows} ->
        previous = Enum.flat_map(rows, &(&1.cidrs || []))
        Ash.Changeset.set_context(changeset, %{@previous => previous})

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp metadata(record, changeset) do
    before = changeset.context[@previous] || []
    after_save = if changeset.action_type == :destroy, do: [], else: record.cidrs || []

    %{
      "state" => if(after_save == [], do: "off", else: "on"),
      "count" => length(after_save),
      "added" => length(after_save -- before),
      "removed" => length(before -- after_save)
    }
  end
end
