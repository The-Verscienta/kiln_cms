defmodule KilnCMSWeb.EnumerationSiteSsoTest do
  @moduledoc """
  A site's own single sign-on does not say what state an account is in (#2255).

  The caller here has already proved, at the site's provider, that they hold the
  address and that its domain is one the site verified, so nothing is disclosed
  about *who they are*. What is guarded is the account's state behind that
  address: whether it exists, has access on another site, was never confirmed,
  or would be refused as new under invite-only. The refusals share one sentence,
  and an existing account and a new one are both signed in with the same
  response.

  `async: false`: the invite-only case flips `:registration_enabled`.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.EnumerationAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.SiteSsoFixtures, as: F

  setup_all do
    %{key: F.signing_key()}
  end

  setup do
    org = KilnCMS.OrgFixtures.org("ssoenum")
    other = KilnCMS.OrgFixtures.org("ssoenum-other")
    domain = F.unique_domain("enum")
    F.provider!(org)
    F.domain!(org, domain, verified: true)
    %{org: org, other: other, domain: domain}
  end

  defp seed_user(email, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp address(domain, tag), do: "#{tag}-#{System.unique_integer([:positive])}@#{domain}"

  # Runs the whole flow for `email` on `org` and returns the callback's conn.
  defp sign_in_as(org, key, email) do
    F.stub_provider!(key, %{})
    conn = build_conn() |> org_conn(org) |> get(~p"/auth/site-sso")

    query =
      conn
      |> redirected_to(302)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    F.stub_provider!(key, %{
      "email" => email,
      "email_verified" => true,
      "nonce" => query["nonce"]
    })

    conn
    |> recycle()
    |> org_conn(org)
    |> get(~p"/auth/site-sso/callback", %{"code" => "c0de", "state" => query["state"]})
  end

  test "an existing account and a new address are signed in alike",
       %{org: org, domain: domain, key: key} do
    known = address(domain, "known")
    unknown = address(domain, "unknown")
    seed_user(known)

    seen =
      assert_indistinguishable(
        fn -> sign_in_as(org, key, known) end,
        fn -> sign_in_as(org, key, unknown) end,
        [known, unknown]
      )

    assert seen.headers == [{"location", "/account"}]
    assert seen.flash == %{"info" => "You are now signed in"}
  end

  test "access elsewhere, an unconfirmed account and an invite-only refusal share one answer",
       %{org: org, other: other, domain: domain, key: key} do
    elsewhere = address(domain, "elsewhere")
    user = seed_user(elsewhere)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: other.id,
      role: :viewer
    })

    unconfirmed = address(domain, "unconfirmed")
    seed_user(unconfirmed, %{confirmed_at: nil})

    previous = Application.get_env(:kiln_cms, :registration_enabled)
    Application.put_env(:kiln_cms, :registration_enabled, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, :registration_enabled),
        else: Application.put_env(:kiln_cms, :registration_enabled, previous)
    end)

    brand_new = address(domain, "brandnew")
    emails = [elsewhere, unconfirmed, brand_new]

    seen =
      assert_indistinguishable(
        fn -> sign_in_as(org, key, elsewhere) end,
        fn -> sign_in_as(org, key, unconfirmed) end,
        emails
      )

    assert_indistinguishable(
      fn -> sign_in_as(org, key, unconfirmed) end,
      fn -> sign_in_as(org, key, brand_new) end,
      emails
    )

    assert seen.headers == [{"location", "/sign-in"}]
    assert seen.flash["error"] =~ "can't use this site's single sign-on"
  end
end
