defmodule KilnCMSWeb.PromotionWarning do
  @moduledoc """
  What an administrator is told when they give someone a tier this site's
  two-step sign-in requirement covers, and that person has no second factor
  (decision 6 on #2247).

  A promotion does not restart the grace period
  (`KilnCMS.Accounts.TwoFactorRequirement.promotion_warning/4`): a
  long-standing viewer made an administrator on a site that requires
  administrators to hold a factor is held at their next page. The warning
  says so before the save (an inline note where the tier is picked) and after
  it (with the confirmation), so the promotion is not a surprise to anyone.
  It never blocks the change.

  `nil` when there is nothing to say: the tier is not covered, the person
  holds a factor, or they are a platform administrator (a membership here does
  not change what they are on this site).

  `platform_message/3` is the Accounts page's version, for a change to an
  account's platform role (standing or temporary): a platform administrator
  is an administrator on every site, so it names the sites that would hold
  them at once and those that give a grace period, with the earliest deadline
  (`TwoFactorRequirement.platform_promotion_warning/3`).
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.TwoFactorRequirement

  @tiers [:admin, :editor, :viewer]

  @doc """
  The warning for making `user` a `tier` on `org_id`, or `nil`. `tier` may be
  the form's string; anything that is not a tier is `nil`. Options are
  `TwoFactorRequirement.promotion_warning/4`'s (`:policy`, `:now`,
  `:tier_source`).
  """
  @spec message(map() | nil, Ash.UUID.t() | nil, atom() | String.t() | nil, keyword()) ::
          String.t() | nil
  def message(user, org_id, tier, opts \\ [])

  def message(%{} = user, org_id, tier, opts) when is_binary(org_id) do
    with tier when tier in @tiers <- to_tier(tier),
         warning when not is_nil(warning) <-
           TwoFactorRequirement.promotion_warning(user, org_id, tier, opts) do
      text(warning, to_string(user.email), tier)
    else
      _nothing -> nil
    end
  end

  def message(_user, _org_id, _tier, _opts), do: nil

  @doc """
  The warning for a change to `before`'s platform role that leaves it as
  `changed` (the saved record), or `nil`. Names up to three sites, and counts
  them beyond that. Options are
  `TwoFactorRequirement.platform_promotion_warning/3`'s (`:now`, `:policies`).
  """
  @spec platform_message(Accounts.User.t(), Accounts.User.t(), keyword()) :: String.t() | nil
  def platform_message(before, changed, opts \\ []) do
    case TwoFactorRequirement.platform_promotion_warning(before, changed, opts) do
      nil -> nil
      warning -> platform_text(warning, changed)
    end
  end

  defp platform_text(%{enforced_now: now, grace: grace}, user) do
    names = site_names(Enum.map(now ++ grace, &elem(&1, 0)))

    [platform_lead(user), held_now(now, names), held_later(grace, names)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp platform_lead(user) do
    if RoleGrant.effective_role(user) == :admin do
      gettext(
        "%{name} has no second factor, and a platform administrator is an administrator on every site.",
        name: to_string(user.email)
      )
    else
      gettext("%{name} has no second factor.", name: to_string(user.email))
    end
  end

  defp held_now([], _names), do: nil

  defp held_now(sites, names) do
    ngettext(
      "%{sites} requires one of them now: they'll be asked to set one up before anything else.",
      "%{sites} require one of them now: they'll be asked to set one up before anything else.",
      length(sites),
      sites: describe_sites(sites, names)
    )
  end

  defp held_later([], _names), do: nil

  defp held_later([{_org_id, earliest} | _] = sites, names) do
    ngettext(
      "%{sites} requires one of them, and gives them until %{date} to set it up.",
      "%{sites} require one of them, with a grace period: the earliest ends %{date}.",
      length(sites),
      sites: describe_sites(sites, names),
      date: on_date(earliest)
    )
  end

  # Up to three sites by name; more, or a site whose name could not be read,
  # by count.
  defp describe_sites(sites, names) do
    labels = Enum.map(sites, fn {org_id, _at} -> Map.get(names, org_id) end)

    if length(labels) <= 3 and Enum.all?(labels, &is_binary/1),
      do: join_names(labels),
      else: ngettext("%{count} site", "%{count} sites", length(labels))
  end

  defp join_names([only]), do: only

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    gettext("%{list} and %{last}", list: Enum.join(init, ", "), last: last)
  end

  defp site_names(org_ids) do
    case Accounts.list_organizations(
           actor: Accounts.system(),
           query: [filter: [id: [in: org_ids]], select: [:id, :name]]
         ) do
      {:ok, orgs} -> Map.new(orgs, &{&1.id, &1.name})
      {:error, _error} -> %{}
    end
  end

  @doc """
  `message` appended to `confirmation` (the save's own flash), or the
  confirmation alone when there is no warning.
  """
  @spec with_confirmation(String.t(), String.t() | nil) :: String.t()
  def with_confirmation(confirmation, nil), do: confirmation
  def with_confirmation(confirmation, warning), do: confirmation <> " " <> warning

  defp text({:enforced_now, deadline}, name, tier) do
    gettext(
      "%{name} has no second factor. This site requires one of %{tier}, and their grace period ended %{date}: they'll be asked to set one up before anything else.",
      name: name,
      tier: tier_label(tier),
      date: on_date(deadline)
    )
  end

  defp text({:grace, deadline}, name, tier) do
    gettext(
      "%{name} has no second factor. This site requires one of %{tier}: they have until %{date} to set it up, and will be asked to before anything else after that.",
      name: name,
      tier: tier_label(tier),
      date: on_date(deadline)
    )
  end

  defp tier_label(:admin), do: gettext("administrators")
  defp tier_label(:editor), do: gettext("editors")
  defp tier_label(:viewer), do: gettext("viewers")

  defp to_tier(tier) when tier in @tiers, do: tier
  defp to_tier(tier) when is_binary(tier), do: Enum.find(@tiers, &(Atom.to_string(&1) == tier))
  defp to_tier(_other), do: nil

  defp on_date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
