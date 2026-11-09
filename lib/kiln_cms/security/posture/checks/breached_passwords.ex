defmodule KilnCMS.Security.Posture.Checks.BreachedPasswords do
  @moduledoc """
  `core.breached_passwords` (#2252): what happens when an administrator sets a
  password that is in a known breach (`KilnCMS.Accounts.PasswordPolicy`,
  #2240). Only `:block` passes; `:warn` warns; `:off`, or the deployment's
  switch off (`BREACHED_PASSWORD_CHECK=false`), fails.

  Asks `PasswordPolicy.read/2` for an administrator: the ladder enforcement
  climbs, but able to say the site's row could not be read, which
  enforcement answers as `:warn` and this as `:unknown`.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.PasswordPolicy
  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.breached_passwords"

  @impl Kiln.Security.Check
  def title, do: gettext("Breached passwords")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A password that has appeared in a breach is among the first an attacker tries. Refusing one for administrators closes that door."
      )

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def run(%{org_id: org_id}) do
    enabled? = BreachedPassword.enabled?()

    opts = [
      fix_path: "/editor/password-policy",
      docs_url: Posture.docs_url("breached-passwords")
    ]

    case PasswordPolicy.read(org_id, :admin) do
      {:ok, :off} when not enabled? ->
        fail(
          gettext(
            "Breached-password checks are off for this installation (BREACHED_PASSWORD_CHECK=false)."
          ),
          Keyword.put(opts, :facts, %{deployment_enabled: false, admin_policy: "off"})
        )

      {:ok, :block} ->
        pass(
          gettext("A breached password is refused for administrators."),
          Keyword.put(opts, :facts, %{deployment_enabled: true, admin_policy: "block"})
        )

      {:ok, :warn} ->
        warn(
          gettext("A breached password is allowed with a warning, administrators included."),
          Keyword.put(opts, :facts, %{deployment_enabled: true, admin_policy: "warn"})
        )

      {:ok, :off} ->
        fail(
          gettext("New passwords are not checked against known breaches."),
          Keyword.put(opts, :facts, %{deployment_enabled: true, admin_policy: "off"})
        )

      :error ->
        unknown(gettext("The site's password policy could not be read."), opts)
    end
  end
end
