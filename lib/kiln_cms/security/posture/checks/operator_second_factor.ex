defmodule KilnCMS.Security.Posture.Checks.OperatorSecondFactor do
  @moduledoc """
  `core.operator_second_factor` (#2252): the deployment's platform
  administrators (an effective platform role of `:admin`, standing or by a
  live grant) who have no authenticator app (TOTP) set up. Fails for any.

  A platform administrator is an administrator of every site, so this is the
  one place they are counted: the per-site `core.second_factor` leaves them
  out. Erased accounts are not counted. A passkey is not counted as a second
  factor (see `KilnCMS.Security.Posture.Checks.SecondFactor`).
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.operator_second_factor"

  @impl Kiln.Security.Check
  def title, do: gettext("Two-step sign-in for platform administrators")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A platform administrator can change every site on this installation, and its users, keys and backups."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def timeout, do: 3000

  @impl Kiln.Security.Check
  def run(_context) do
    platform_admin = RoleGrant.expression([:admin])

    query =
      Accounts.User
      |> Ash.Query.filter(^platform_admin and is_nil(anonymized_at))
      |> Ash.Query.select([:id, :email, :totp_confirmed_at])
      |> Ash.Query.sort(email: :asc)

    # authorize?: false — a roster of the deployment's platform
    # administrators: `User`'s read policy is self-only, and only the count and
    # addresses below reach the page, which only platform administrators open.
    admins = Accounts.list_users!(query: query, authorize?: false)
    without = Enum.reject(admins, &Accounts.totp_enabled?/1)

    opts = [
      details: Posture.listed(Enum.map(without, &to_string(&1.email))),
      fix_path: "/editor/settings",
      docs_url: Posture.docs_url("two-step-sign-in"),
      facts: %{platform_admins: length(admins), platform_admins_without: length(without)}
    ]

    cond do
      without != [] ->
        fail(
          ngettext(
            "%{count} platform administrator has no authenticator app.",
            "%{count} platform administrators have no authenticator app.",
            length(without)
          ),
          opts
        )

      admins == [] ->
        n_a(gettext("This installation has no platform administrators."), opts)

      true ->
        pass(gettext("Every platform administrator uses an authenticator app."), opts)
    end
  end
end
