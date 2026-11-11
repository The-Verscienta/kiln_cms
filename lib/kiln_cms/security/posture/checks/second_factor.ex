defmodule KilnCMS.Security.Posture.Checks.SecondFactor do
  @moduledoc """
  `core.second_factor` (#2252): the site's administrators and editors who have
  no authenticator app (TOTP) set up.

  Fails when any administrator has none, warns when only editors do. The
  roster is `KilnCMS.Accounts.Scoping.users_with_tier_query/2`, the same
  inverse of `effective_tier/2` the review and assignee rosters use, run once
  for `:admin` and once for `:editor`, so the two lists are disjoint and a
  membership admin whose own account is a viewer is counted as an admin.
  Platform administrators are left out: they are on every site, and the
  deployment's `core.operator_second_factor` reports them. Erased accounts,
  and registrations not (or not yet) approved, are not counted.

  A passkey is not counted as a second factor: it is a way to sign in, and
  does not protect the password sign-in of the same account.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.second_factor"

  @impl Kiln.Security.Check
  def title, do: gettext("Two-step sign-in for administrators and editors")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A stolen or guessed password is enough to sign in to an account without an authenticator app. Administrators can change every setting on this page."
      )

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def timeout, do: 3000

  @impl Kiln.Security.Check
  def run(%{org_id: org_id}) do
    admins = roster(org_id, :admin)
    editors = roster(org_id, :editor)
    admins_without = Enum.reject(admins, &Accounts.totp_enabled?/1)
    editors_without = Enum.reject(editors, &Accounts.totp_enabled?/1)

    opts = [
      details: names(admins_without ++ editors_without),
      fix_path: "/editor/settings",
      docs_url: Posture.docs_url("two-step-sign-in"),
      facts: %{
        admins: length(admins),
        editors: length(editors),
        admins_without: length(admins_without),
        editors_without: length(editors_without)
      }
    ]

    cond do
      admins_without != [] ->
        fail(
          ngettext(
            "%{count} administrator has no authenticator app. A passkey doesn't protect password sign-in.",
            "%{count} administrators have no authenticator app. A passkey doesn't protect password sign-in.",
            length(admins_without)
          ),
          opts
        )

      editors_without != [] ->
        warn(
          ngettext(
            "%{count} editor has no authenticator app.",
            "%{count} editors have no authenticator app.",
            length(editors_without)
          ),
          opts
        )

      admins == [] and editors == [] ->
        n_a(gettext("This site has no administrators or editors of its own."), opts)

      true ->
        pass(gettext("Every administrator and editor uses an authenticator app."), opts)
    end
  end

  # Disjoint by construction: the `:admin` roster and the `:editor` roster are
  # each one tier, and platform administrators (the only accounts the `:admin`
  # roster adds beyond members) are filtered out of both.
  defp roster(org_id, tier) do
    platform_admin = RoleGrant.expression([:admin])

    query =
      org_id
      |> Scoping.users_with_tier_query([tier])
      |> Ash.Query.filter(not (^platform_admin) and is_nil(anonymized_at))
      |> Ash.Query.select([:id, :email, :totp_confirmed_at])
      |> Ash.Query.sort(email: :asc)

    # authorize?: false — a roster of the site's people, as the review-request
    # roster reads it (`Scoping.users_with_tier/2`): `User`'s read policy is
    # self-only, and only the counts and addresses below reach the page, which
    # only this site's administrators can open.
    Accounts.list_users!(query: query, authorize?: false)
  end

  defp names(users), do: Posture.listed(Enum.map(users, &to_string(&1.email)))
end
