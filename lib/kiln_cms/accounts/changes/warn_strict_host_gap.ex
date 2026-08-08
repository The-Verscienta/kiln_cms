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

  ## Best-effort, always

  `after_action`, and every failure swallowed. A warning is not worth failing a
  create over, and a change that raises here would roll back the organization —
  turning an advisory into an outage. The count runs inside the create's
  transaction, so it already includes the new row: `> 1` means *this* create is
  the one that crossed the line.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &warn/2)
  end

  defp warn(_changeset, org) do
    if KilnCMSWeb.Tenant.strict_host_gap?() do
      Logger.warning(
        "Created organization #{inspect(org.slug)}, which makes this deployment " <>
          "multi-tenant — but TENANT_STRICT_HOST is off. A request whose Host matches " <>
          "no organization is served the DEFAULT org's content, branding and " <>
          "analytics. Set TENANT_STRICT_HOST=true to reject those instead; see " <>
          "docs/environment-variables.md."
      )
    end

    {:ok, org}
  rescue
    # Never let an advisory roll back the create.
    _error -> {:ok, org}
  end
end
