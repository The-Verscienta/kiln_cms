defmodule KilnCMS.Security.Posture.Checks.ApiKeys do
  @moduledoc """
  `core.api_keys` (#2252): the deployment's API keys that are valid (not
  revoked, not expired, at the report's `now`).

  Fails for a `:read_write` key owned by an administrator: such a key can
  author content anywhere its owner can, and an owner is an administrator if
  they hold an admin tier anywhere now (a platform admin, standing or by a
  live grant, or an active admin membership of any site). Warns for a key
  created more than #{180} days ago (age stands in for "unused" until keys
  record their last use) or expiring more than #{365} days from now. No valid
  key is `:n_a`.

  A key whose scope this release does not know (#2604: minted by a newer
  release, met after a rollback or during a rolling deploy) does not sign in
  here, so it is not counted in `valid_keys`, which means the keys that sign
  in on this release. It is counted in `unrecognized_scope_keys` and warns,
  never fails: a release that knows the scope signs it in again, so an
  operator reviews it and revokes it if it is not wanted. During a rollout the
  check can differ by node (a node on the older release warns, one on the
  newer passes), each cached for its own report.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey.Scope
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Security.Posture

  @old_days 180
  @long_lived_days 365

  @impl Kiln.Security.Check
  def id, do: "core.api_keys"

  @impl Kiln.Security.Check
  def title, do: gettext("API keys")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "An API key works without a password or a second factor, for as long as it is valid. Keep keys narrow and short-lived."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def timeout, do: 3000

  @impl Kiln.Security.Check
  def run(%{now: now}) do
    query =
      Accounts.ApiKey
      # An erased account's key is refused at sign-in (`User.valid_api_keys`)
      # even before the erasure backfill revokes it, so it is left out here.
      |> Ash.Query.filter(is_nil(revoked_at) and expires_at > ^now and is_nil(user.anonymized_at))
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.load(user: [:org_memberships])

    # authorize?: false — every key on the deployment, which the `ApiKey`
    # policy shows to platform admins only; this check is `:deployment`, so
    # only platform admins see what it reports, and it reports names and
    # counts, never a key.
    live = Accounts.list_all_api_keys!(query: query, authorize?: false)

    # A scope this release does not know (#2604) is refused at sign-in too, so
    # those keys are counted apart from the ones that sign in here.
    {keys, unrecognized} = Enum.split_with(live, &Scope.known?(&1.access))

    admin_write = Enum.filter(keys, &(&1.access == :read_write and admin_owner?(&1.user)))
    old = Enum.filter(keys, &older_than?(&1.created_at, now, @old_days))
    long_lived = Enum.filter(keys, &later_than?(&1.expires_at, now, @long_lived_days))
    review = Enum.uniq_by(old ++ long_lived ++ unrecognized, & &1.id)

    opts = [
      fix_path: "/editor/api-keys",
      docs_url: Posture.docs_url("api-keys"),
      facts: %{
        valid_keys: length(keys),
        admin_read_write: length(admin_write),
        older_than_180_days: length(old),
        expiring_after_365_days: length(long_lived),
        unrecognized_scope_keys: length(unrecognized)
      }
    ]

    cond do
      keys == [] and unrecognized == [] ->
        n_a(gettext("No API keys are valid."), opts)

      admin_write != [] ->
        fail(
          ngettext(
            "%{count} key can write content as an administrator.",
            "%{count} keys can write content as an administrator.",
            length(admin_write)
          ),
          # The unrecognized-scope keys too, so fixing the admin key is not
          # the first time they are named.
          Keyword.put(opts, :details, labels(admin_write ++ unrecognized))
        )

      review != [] ->
        warn(
          warning(old ++ long_lived, unrecognized),
          Keyword.put(opts, :details, labels(review))
        )

      true ->
        pass(
          ngettext(
            "%{count} valid key, none of them an administrator's write key, old or long-lived.",
            "%{count} valid keys, none of them an administrator's write key, old or long-lived.",
            length(keys)
          ),
          opts
        )
    end
  end

  defp warning(_aged, []),
    do:
      gettext(
        "Some keys are over 180 days old (their age stands in for last use, which keys don't record yet) or expire more than a year from now."
      )

  defp warning([], unrecognized),
    do: unrecognized_warning(unrecognized)

  defp warning(_aged, unrecognized),
    do:
      gettext(
        "%{unrecognized} Some keys are also over 180 days old (their age stands in for last use, which keys don't record yet) or expire more than a year from now.",
        unrecognized: unrecognized_warning(unrecognized)
      )

  defp unrecognized_warning(unrecognized) do
    ngettext(
      "%{count} key has a scope this release does not know: it does not sign in here, but will on a release that knows the scope. Revoke it if it is not wanted.",
      "%{count} keys have a scope this release does not know: they do not sign in here, but will on a release that knows the scope. Revoke them if they are not wanted.",
      length(unrecognized)
    )
  end

  # An administrator anywhere, now: the platform role (with a live grant), or
  # an active admin membership of any site.
  defp admin_owner?(%{} = user) do
    RoleGrant.effective_role(user) == :admin or
      Enum.any?(List.wrap(user.org_memberships), fn membership ->
        membership.status == :active and RoleGrant.effective_role(membership) == :admin
      end)
  end

  defp admin_owner?(_no_user), do: false

  defp older_than?(%DateTime{} = at, now, days),
    do: DateTime.compare(at, DateTime.add(now, -days, :day)) == :lt

  defp older_than?(_at, _now, _days), do: false

  defp later_than?(%DateTime{} = at, now, days),
    do: DateTime.compare(at, DateTime.add(now, days, :day)) == :gt

  defp later_than?(_at, _now, _days), do: false

  defp labels(keys) do
    keys
    |> Enum.map(fn key ->
      owner = if key.user, do: to_string(key.user.email), else: "?"
      "#{key.name} (#{owner})"
    end)
    |> Posture.listed()
  end
end
