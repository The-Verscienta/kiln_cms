defmodule KilnCMS.Staging.ScrubErasureTest do
  @moduledoc """
  The staging scrub erases every account through `:anonymize`, which deletes
  each account's linked newsletter rows (#2991). The scrub runs that action
  `authorize?: false`, and the newsletter step authorizes as its own system
  actor, so the scrub must still complete over a member with a linked row.
  (It purges every subscriber afterwards regardless; this pins only that the
  erasure step in the middle does not stop it.)

  The same erasure demotes every site membership (#2774), so a clone's site
  admins hold no tier once scrubbed, and the staging admin the scrub
  provisions is the one admin left.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Newsletter
  alias KilnCMS.Staging.Scrub

  test "completes over an account with a linked newsletter subscription" do
    member =
      Ash.Seed.seed!(Accounts.User, %{
        email: "scrub-member-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    opts = [authorize?: false, tenant: Accounts.default_org_id()]

    member.id
    |> Newsletter.link_member_subscriber!(%{email: to_string(member.email)}, opts)
    |> Newsletter.confirm_subscriber!(opts)

    assert %{users_anonymized: anonymized} = Scrub.run([])
    assert anonymized >= 1

    assert Accounts.get_user!(member.id, authorize?: false).anonymized_at
  end

  test "demotes every member's site tier, and the staging admin is admin" do
    member =
      Ash.Seed.seed!(Accounts.User, %{
        email: "scrub-site-admin-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    site = Accounts.default_org_id()

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: member.id,
      organization_id: site,
      role: :admin
    })

    email = "staging-admin-#{System.unique_integer([:positive])}@example.com"

    assert %{users_anonymized: _} =
             Scrub.run(admin_email: email, admin_password: "staging-pass-123")

    assert %{role: :viewer} = Accounts.get_org_membership!(member.id, site, authorize?: false)
    refute member.id in Enum.map(Accounts.Scoping.users_with_tier(site, [:admin]), & &1.id)

    [staging_admin] = Accounts.list_users!(authorize?: false, query: [filter: [email: email]])
    assert Accounts.Scoping.effective_tier(staging_admin, site) == :admin
  end
end
