defmodule KilnCMS.Staging.ScrubErasureTest do
  @moduledoc """
  The staging scrub erases every account through `:anonymize`, which deletes
  each account's linked newsletter rows (#2991). The scrub runs that action
  `authorize?: false`, and the newsletter step authorizes as its own system
  actor, so the scrub must still complete over a member with a linked row.
  (It purges every subscriber afterwards regardless; this pins only that the
  erasure step in the middle does not stop it.)
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
end
