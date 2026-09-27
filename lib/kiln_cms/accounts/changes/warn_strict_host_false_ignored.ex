defmodule KilnCMS.Accounts.Changes.WarnStrictHostFalseIgnored do
  @moduledoc """
  Log an error when the organization just created is the one that makes this
  deployment multi-tenant while `TENANT_STRICT_HOST=false` is set (#1662).

  Until 0.12 that combination served every unrecognized `Host` — a bare
  hostname, an IP, an attacker-supplied header — the **default org's** content,
  branding and analytics, and this change (then `WarnStrictHostGap`, #660)
  warned about the leak. Kiln no longer honours `false` once a second
  organization exists: `KilnCMS.Accounts.Changes.RecordOrgCount`, which runs
  first, moves the verdict to `:multi`, and routing refuses those hosts from
  this create on (`KilnCMSWeb.Tenant.strict_host?/0`). What is left to say is
  the other surprise — an explicit setting is being overridden, and anything
  that relied on the fallback now gets a 404 — so it is an error, not a
  warning.

  ## Why here, when boot already checks

  `KilnCMS.Application` runs the same predicate at startup. That catches a
  deployment that *restarts* while configured this way — but the moment the
  behaviour changes is org creation, and on an instance that has been up for
  months boot already happened. This is the log line at the moment the
  condition becomes true.

  ## Only the crossing

  Exactly two organizations — the create that changed what `false` does. The
  third and later ones are the same configuration, but saying so again per
  create would give a SaaS a permanent error on every provisioning event, and
  an error an operator learns to scroll past is worse than none. The standing
  state is `/editor/system`'s job, and it says it every time someone looks.

  ## After the transaction, not inside it

  `after_transaction`, matching only `{:ok, _}`. `after_action` was the obvious
  place — the count inside the create's transaction already includes the new row
  — but it puts a database read inside the operation it is advising about. A
  read that fails there aborts the Postgres transaction, and no `rescue` can
  save it: the create returns an opaque `{:error, :rollback}` and the
  organization is gone, which is a far worse outcome than a missing log line.
  Post-commit the count still includes the new row, so nothing is lost.

  The `rescue` stays as defence in depth for the same reason — an advisory must
  not be able to raise into the caller — but it is no longer the only thing
  standing between a slow `SELECT` and a lost organization.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMSWeb.Tenant

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &warn/2)
  end

  defp warn(_changeset, {:ok, org} = result) do
    count = Tenant.org_count()

    if count == 2 and Tenant.false_ignored?(count) do
      Logger.error(
        "Created organization #{inspect(org.slug)}, the second on this deployment. " <>
          Tenant.strict_host_false_ignored_message()
      )
    end

    result
  rescue
    # Never let an advisory raise into the caller of a committed create.
    _error -> result
  end

  defp warn(_changeset, other), do: other
end
