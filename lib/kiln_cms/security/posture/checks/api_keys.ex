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
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias KilnCMS.Accounts
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
      |> Ash.Query.filter(is_nil(revoked_at) and expires_at > ^now)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.load(user: [:org_memberships])

    # authorize?: false — every key on the deployment, which the `ApiKey`
    # policy shows to platform admins only; this check is `:deployment`, so
    # only platform admins see what it reports, and it reports names and
    # counts, never a key.
    keys = Accounts.list_all_api_keys!(query: query, authorize?: false)

    admin_write = Enum.filter(keys, &(&1.access == :read_write and admin_owner?(&1.user)))
    old = Enum.filter(keys, &older_than?(&1.created_at, now, @old_days))
    long_lived = Enum.filter(keys, &later_than?(&1.expires_at, now, @long_lived_days))

    opts = [
      fix_path: "/editor/api-keys",
      docs_url: Posture.docs_url("api-keys"),
      facts: %{
        valid_keys: length(keys),
        admin_read_write: length(admin_write),
        older_than_180_days: length(old),
        expiring_after_365_days: length(long_lived)
      }
    ]

    cond do
      keys == [] ->
        n_a(gettext("No API keys are valid."), opts)

      admin_write != [] ->
        fail(
          ngettext(
            "%{count} key can write content as an administrator.",
            "%{count} keys can write content as an administrator.",
            length(admin_write)
          ),
          Keyword.put(opts, :details, labels(admin_write))
        )

      old != [] or long_lived != [] ->
        warn(
          gettext(
            "Some keys are over 180 days old (their age stands in for last use, which keys don't record yet) or expire more than a year from now."
          ),
          Keyword.put(opts, :details, labels(Enum.uniq_by(old ++ long_lived, & &1.id)))
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
