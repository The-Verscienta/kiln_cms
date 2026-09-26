defmodule KilnCMS.Accounts.Changes.WarnEmbedOverreach do
  @moduledoc """
  Warn when the organization just created is the one that turns an unset
  `EMBED_ORIGINS_LOCKED` on, and stored form or site-wide embed allowlists name
  sites outside `EMBED_ORIGINS` (#1618).

  Unset, the cap is auto: off with one organization, on once a second exists
  (`KilnCMS.Forms.EmbedCeiling.locked?/0`, which reads the verdict
  `KilnCMS.Accounts.Changes.RecordOrgCount` has just moved — so this is declared
  after it). The lists are not rewritten; `KilnCMS.Forms.EmbedPolicy` clamps
  them when served, so a partner site that framed a form a minute ago gets a
  blank iframe, and nobody decided that — creating an organization did. Boot
  reports the same thing (`KilnCMS.Application`), but on a running instance
  boot already happened; this is the log line at the moment it becomes true.

  Only the crossing — exactly two organizations, with the setting unset — for
  the reason `KilnCMS.Accounts.Changes.WarnStrictHostGap` gives: an explicit
  `true` capped the lists long before, and a per-provisioning repeat is a
  warning an operator learns to scroll past. `/editor/system` carries the
  standing state.

  `after_transaction`, only on `{:ok, _}`, and total: the check reads the
  database, and an advisory must never abort or raise into a committed create.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Forms.EmbedCeiling
  alias KilnCMSWeb.Tenant

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &warn/2)
  end

  defp warn(_changeset, {:ok, org} = result) do
    with :auto <- EmbedCeiling.setting(),
         2 <- Tenant.org_count(),
         message when is_binary(message) <- EmbedCeiling.overreach_warning() do
      Logger.warning(
        "Created organization #{inspect(org.slug)}, the second on this deployment. " <>
          message
      )
    end

    result
  rescue
    # Never let an advisory raise into the caller of a committed create.
    _error -> result
  end

  defp warn(_changeset, other), do: other
end
