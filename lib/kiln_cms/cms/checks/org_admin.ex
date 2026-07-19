defmodule KilnCMS.CMS.Checks.OrgAdmin do
  @moduledoc """
  Matches an actor whose **effective tier on the request's org** is `:admin`
  (#419 — per-org capability tiers).

  Replaces `actor_attribute_equals(:role, :admin)` on org-scoped resources:
  the tier resolves through `KilnCMS.Accounts.Scoping.effective_tier/2`
  (membership tier on this org; platform admins pass everywhere; affiliated
  users have no tier on foreign orgs; membership-less accounts keep
  `User.role`). Platform resources (user/org/membership administration) keep
  the global check — that's where tiers are granted.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.Scoping

  @impl Ash.Policy.Check
  def describe(_opts), do: "an admin of the request's organization"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{subject: subject}, _opts) do
    Scoping.effective_tier(actor, subject) == :admin
  end
end
