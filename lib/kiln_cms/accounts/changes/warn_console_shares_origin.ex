defmodule KilnCMS.Accounts.Changes.WarnConsoleSharesOrigin do
  @moduledoc """
  Warn when the organization just created is the one that makes this
  deployment multi-tenant while `KILN_CONSOLE_HOST` is unset (#1661).

  With one organization, the org admin who can add code injection (`head_html`
  / `footer_html`, #490) and the operator are the same party. With two, that
  snippet runs on a public site that is same-origin with the editor console,
  so it can act with the session of any editor who opens the site while signed
  in — a platform admin, who is an admin on every org, included. See
  `docs/code-injection.md` and `KilnCMSWeb.Tenant.console_shares_origin?/0`.

  Accepted at 1.0 with a warning rather than forced (threat model, residual
  risk 16): a console host is a deployment change — DNS, TLS, `CHECK_ORIGINS`
  — that Kiln cannot make for an operator on upgrade. So it is said at the
  three places #660 established: boot (`KilnCMS.Application`), this create,
  and `/editor/system`.

  Only the crossing — exactly two organizations — and `after_transaction`,
  only on `{:ok, _}`, total: the reasons
  `KilnCMS.Accounts.Changes.WarnStrictHostFalseIgnored` gives.
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

    if count == 2 and Tenant.console_shares_origin?(count) do
      Logger.warning(
        "Created organization #{inspect(org.slug)}, the second on this deployment. " <>
          Tenant.console_shares_origin_message()
      )
    end

    result
  rescue
    # Never let an advisory raise into the caller of a committed create.
    _error -> result
  end

  defp warn(_changeset, other), do: other
end
