defmodule KilnCMS.Newsletter.ErasureStrictTest do
  @moduledoc """
  Erasure's newsletter step and the data-subject export's newsletter half
  (#2991) under strict tenancy (#419, the production default), where a
  tenant-less read or write of `Subscriber` is refused outright.

  Both go org by org with the org as the tenant, so they must work here. The
  main suite compiles fail-open, where a tenant-less call would quietly have
  resolved the default org and passed, so this runs on the strict CI leg only.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :strict_tenancy

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Newsletter

  defp member do
    Ash.Seed.seed!(Accounts.User, %{
      email: "nl-strict-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp linked(user, org_id) do
    opts = [authorize?: false, tenant: org_id]

    user.id
    |> Newsletter.link_member_subscriber!(%{email: to_string(user.email)}, opts)
    |> Newsletter.confirm_subscriber!(opts)
  end

  defp exists?(subscriber) do
    Newsletter.get_subscriber(subscriber.id,
      authorize?: false,
      tenant: subscriber.org_id,
      not_found_error?: false
    ) != {:ok, nil}
  end

  test "the export lists the member's rows on every site" do
    user = member()
    org_a = org("nl-strict-a").id
    org_b = org("nl-strict-b").id
    linked(user, org_a)
    linked(user, org_b)

    assert Accounts.export_user_data(user).newsletter_subscriptions
           |> Enum.map(& &1.org_id)
           |> Enum.sort() == Enum.sort([org_a, org_b])
  end

  test "forget_member/1 deletes the member's rows on every site, and only theirs" do
    user = member()
    here = linked(user, org("nl-strict-c").id)
    there = linked(user, org("nl-strict-d").id)
    other = linked(member(), here.org_id)

    assert :ok = Newsletter.forget_member(user.id)

    refute exists?(here)
    refute exists?(there)
    assert exists?(other)
  end
end
