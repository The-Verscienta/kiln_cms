defmodule KilnCMS.Accounts.Changes.WarnStrictHostGap do
  @moduledoc """
  Warn when the organization just created is the one that makes this deployment
  multi-tenant while `TENANT_STRICT_HOST` is still off (#660).

  ## Why here, when boot already checks

  `KilnCMS.Application` runs the same predicate at startup. That catches a
  deployment that *restarts* while misconfigured — but the risky moment is org
  creation, and boot already happened. On an instance that has been up for
  months, creating the second org silently puts every unrecognized `Host` — a
  bare hostname, an IP, an attacker-supplied header — onto the **default org's**
  content, branding and analytics, and nothing says so until the next deploy.

  #563 shipped a CHANGELOG `### Upgrading` note, which helps an operator reading
  it at the right moment. This is the log line for everyone else, at the moment
  the condition becomes true.

  ## Only the crossing

  Exactly two organizations — the create that made the fallback start meaning
  something. The third and later ones are the same misconfiguration, but saying
  so again per create would give a SaaS that has deliberately left the flag off a
  permanent warning on every provisioning event, and a warning an operator learns
  to scroll past is worse than none. The standing state is `/editor/system`'s
  job, and it says it every time someone looks.

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

    if count == 2 and Tenant.gap?(count) do
      Logger.warning(
        "Created organization #{inspect(org.slug)}, the second on this deployment — " <>
          "so the Host header now decides which site a request gets, and " <>
          "TENANT_STRICT_HOST is off. A request whose Host matches no organization " <>
          "is served the DEFAULT org's content, branding and analytics. Set " <>
          "TENANT_STRICT_HOST=true to reject those instead; see " <>
          "docs/environment-variables.md."
      )
    end

    result
  rescue
    # Never let an advisory raise into the caller of a committed create.
    _error -> result
  end

  defp warn(_changeset, other), do: other
end
