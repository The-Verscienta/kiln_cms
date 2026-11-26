defmodule KilnCMS.Security.Posture.Checks.BreachedPasswords do
  @moduledoc """
  `core.breached_passwords` (#2252): what happens when an administrator sets a
  password that is in a known breach (`KilnCMS.Accounts.PasswordPolicy`,
  #2240). Only `:block` passes; `:warn` warns; `:off`, or the deployment's
  switch off (`BREACHED_PASSWORD_CHECK=false`), fails.

  Asks `PasswordPolicy.read/2` for an administrator: the ladder enforcement
  climbs, but able to say the site's row could not be read, which
  enforcement answers as `:warn` and this as `:unknown`.

  The `sign_in_check` fact says whether the site also checks its
  administrators' passwords when they sign in (#2407,
  `PasswordPolicy.read_sign_in_check/1`), and is false while the deployment's
  switch is off. It does not change the status.
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

    sign_in_check = sign_in_check(org_id, enabled?)

    case PasswordPolicy.read(org_id, :admin) do
      {:ok, :off} when not enabled? ->
        fail(
          gettext(
            "Breached-password checks are off for this installation (BREACHED_PASSWORD_CHECK=false)."
          ),
          Keyword.put(
            opts,
            :facts,
            Map.merge(%{deployment_enabled: false, admin_policy: "off"}, sign_in_check)
          )
        )

      {:ok, :block} ->
        pass(
          gettext("A breached password is refused for administrators."),
          Keyword.put(
            opts,
            :facts,
            Map.merge(%{deployment_enabled: true, admin_policy: "block"}, sign_in_check)
          )
        )

      {:ok, :warn} ->
        warn(
          gettext("A breached password is allowed with a warning, administrators included."),
          Keyword.put(
            opts,
            :facts,
            Map.merge(%{deployment_enabled: true, admin_policy: "warn"}, sign_in_check)
          )
        )

      {:ok, :off} ->
        fail(
          gettext("New passwords are not checked against known breaches."),
          Keyword.put(
            opts,
            :facts,
            Map.merge(%{deployment_enabled: true, admin_policy: "off"}, sign_in_check)
          )
        )

      :error ->
        unknown(gettext("The site's password policy could not be read."), opts)
    end
  end

  # Omitted when the row cannot be read: a fact the check cannot see is not
  # reported as false.
  defp sign_in_check(org_id, enabled?) do
    case PasswordPolicy.read_sign_in_check(org_id) do
      {:ok, check?} -> %{sign_in_check: enabled? and check?}
      :error -> %{}
    end
  end
end
