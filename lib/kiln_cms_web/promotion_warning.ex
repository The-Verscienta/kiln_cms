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
  """
  use Gettext, backend: KilnCMSWeb.Gettext

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
