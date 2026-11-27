defmodule KilnCMS.Mail.ErasureSuppressionStrictTest do
  @moduledoc """
  Erasure's suppression step (#3036) under strict tenancy (#419, the
  production default), where a tenant-less read or write of
  `SiteSuppressedRecipient` is refused outright.

  `KilnCMS.Mail.forget_suppressions/2` visits the site lists one org at a
  time with the org as the tenant, so it must work here. The main suite
  compiles fail-open, where a tenant-less call would quietly have resolved
  the default org and passed, so this runs on the strict CI leg only.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :strict_tenancy

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Mail

  defp user(role, email) do
    Ash.Seed.seed!(Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp site_list(site) do
    Mail.list_site_suppressed_recipients!(authorize?: false, tenant: site)
    |> Enum.map(&to_string(&1.email))
  end

  test "erasure drops the address from every site's list, and only that address" do
    site_a = org("supp-strict-a")
    site_b = org("supp-strict-b")
    n = System.unique_integer([:positive])
    subject = user(:viewer, "Strict-#{n}@example.com")
    other = "strict-other-#{n}@example.com"

    for site <- [site_a, site_b], email <- ["STRICT-#{n}@example.com", other] do
      Mail.suppress_site_recipient!(%{email: email}, actor: Mail.system(), tenant: site)
    end

    Mail.suppress_recipient!(%{email: "strict-#{n}@example.com"}, actor: Mail.system())

    Accounts.anonymize_user!(subject, actor: user(:admin, "strict-admin-#{n}@example.com"))

    assert site_list(site_a) == [other]
    assert site_list(site_b) == [other]
    assert Mail.list_suppressed_recipients!(authorize?: false) == []
  end
end
