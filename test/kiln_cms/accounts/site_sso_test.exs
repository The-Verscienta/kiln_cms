defmodule KilnCMS.Accounts.SiteSsoTest do
  @moduledoc """
  A site's own single sign-on provider (#1561): the rows
  (`KilnCMS.CMS.SiteSsoProvider`, `KilnCMS.CMS.SiteSsoDomain`), the flow
  (`KilnCMS.Accounts.SiteSso`) and the admission rule
  (`KilnCMS.Accounts.SiteSso.Admission`).

  What each group pins, because each is a way this could quietly become an
  account takeover:

    * **domain verification** — an assertion for an address outside the site's
      verified domains is refused: never verified, verified by *another* site,
      a subdomain, or a record that has since been taken down;
    * **cross-site isolation** — site A's provider cannot produce a session for
      a site-B admin, a platform admin, or any account with access elsewhere;
    * **the protocol** — the real Assent callback runs: a token signed by the
      wrong key, with `HS256`, or from a provider whose discovery names another
      issuer is refused;
    * **SSRF** — a private issuer is refused at save and at sign-in, and so is a
      private or plain-HTTP endpoint named by the discovery document;
    * **fail direction** — an unusable row makes site SSO unavailable; it never
      becomes the operator's provider;
    * **the operator's provider** — still compiled, still read from its own
      config, and never given a site's identities.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SiteSso
  alias KilnCMS.Accounts.SiteSso.Admission
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.SiteSsoFixtures, as: F

  @redirect_uri "https://site.example/auth/site-sso/callback"

  setup_all do
    %{key: F.signing_key()}
  end

  setup do
    org = KilnCMS.OrgFixtures.org("sso")
    other = KilnCMS.OrgFixtures.org("sso-other")
    domain = F.unique_domain()
    F.provider!(org)
    F.domain!(org, domain, verified: true)
    %{org: org, other: other, domain: domain}
  end

  defp user!(email, attrs \\ %{}) do
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

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: role
    })
  end

  defp claims(email, extra \\ %{}),
    do: Map.merge(%{"email" => email, "email_verified" => true, "sub" => "s-1"}, extra)

  # The whole flow, through the real Assent callback: authorize, then answer
  # the token endpoint with an ID token carrying the flow's own nonce.
  defp full_flow(org, key, claims, opts \\ []) do
    F.stub_provider!(key, %{}, opts)
    {:ok, %{url: url, session_params: session_params}} = SiteSso.authorize(org.id, @redirect_uri)

    F.stub_provider!(key, Map.put(claims, "nonce", session_params.nonce), opts)

    SiteSso.sign_in(
      org.id,
      @redirect_uri,
      %{"code" => "the-code", "state" => session_params.state},
      session_params
    )
    |> then(&{&1, url})
  end

  describe "the full flow" do
    test "a new address in a verified domain gets an account, a membership here only, and a token",
         %{org: org, domain: domain, key: key} do
      email = "new@#{domain}"

      {{:ok, user}, url} = full_flow(org, key, claims(email, %{"name" => "New Person"}))

      assert url =~ F.issuer() <> "/authorize?"
      assert url =~ "code_challenge="
      assert url =~ "nonce="
      assert to_string(user.email) == email
      assert is_binary(user.__metadata__.token)
      assert user.role == :viewer
      assert user.name == "New Person"

      assert [%{organization_id: org_id, role: :viewer}] =
               Accounts.list_memberships_for_user!(user.id, authorize?: false)

      assert org_id == org.id
    end

    test "the token endpoint is sent the client secret, by basic auth, and the PKCE verifier",
         %{org: org, domain: domain, key: key} do
      {{:ok, _user}, _url} =
        full_flow(org, key, claims("pkce@#{domain}"), test_pid: self())

      assert_receive {:token_request, body, headers}
      assert body =~ "code_verifier="
      {"authorization", "Basic " <> basic} = List.keyfind(headers, "authorization", 0)
      assert Base.decode64!(basic) == "#{F.client_id()}:#{F.client_secret()}"
    end

    test "an ID token signed by a key the provider does not publish is refused",
         %{org: org, domain: domain, key: key} do
      stranger = F.signing_key("test-key")

      assert {{:error, {:provider, _}}, _url} =
               full_flow(org, key, claims("forged@#{domain}"), sign_with: stranger)

      assert {:error, _} = Accounts.get_user_by_email("forged@#{domain}", authorize?: false)
    end

    test "an HS256 ID token (verifiable with the client secret this server holds) is refused",
         %{org: org, domain: domain, key: key} do
      assert {{:error, {:provider, _}}, _url} =
               full_flow(org, key, claims("hmac@#{domain}"), alg: "HS256")
    end

    test "a discovery document naming another issuer is refused", %{org: org, key: key} do
      F.stub_provider!(key, %{}, discovery: %{"issuer" => "https://evil.example.test"})

      assert {:error, {:provider, "discovery document names a different issuer"}} =
               SiteSso.authorize(org.id, @redirect_uri)
    end
  end

  describe "domain verification" do
    test "an address outside every verified domain is refused", %{org: org} do
      user!("admin@elsewhere.example")

      assert {:error, :domain_not_verified} =
               Admission.admit(org.id, claims("admin@elsewhere.example"))
    end

    test "through the real flow too: no session for an unverified domain", %{org: org, key: key} do
      assert {{:error, :domain_not_verified}, _url} =
               full_flow(org, key, claims("someone@not-verified.example"))
    end

    test "a listed but never-verified domain is refused, even with its record published",
         %{org: org} do
      pending = F.unique_domain("pending")
      org |> F.domain!(pending) |> F.publish!()

      assert {:error, :domain_not_verified} = Admission.admit(org.id, claims("a@#{pending}"))
    end

    test "a verified domain whose record has been taken down stops being honoured",
         %{org: org} do
      gone = F.unique_domain("gone")
      row = F.domain!(org, gone, verified: true)
      assert {:ok, _user} = Admission.admit(org.id, claims("still@#{gone}"))

      F.unpublish!(row)

      assert {:error, :domain_not_verified} = Admission.admit(org.id, claims("still@#{gone}"))
    end

    test "a domain another site verified is not this site's to vouch for",
         %{org: org, other: other} do
      theirs = F.unique_domain("theirs")
      F.domain!(other, theirs, verified: true)

      assert {:error, :domain_not_verified} = Admission.admit(org.id, claims("x@#{theirs}"))
    end

    test "a verified domain does not cover its subdomains", %{org: org, domain: domain} do
      assert {:error, :domain_not_verified} =
               Admission.admit(org.id, claims("x@mail.#{domain}"))
    end

    test "only the last @ decides the domain", %{org: org, domain: domain} do
      assert {:error, :domain_not_verified} =
               Admission.admit(org.id, claims("\"x@#{domain}\"@evil.example"))
    end

    test "the provider must itself verify the email", %{org: org, domain: domain} do
      assert {:error, :email_unverified} =
               Admission.admit(org.id, claims("u@#{domain}", %{"email_verified" => false}))

      assert {:error, :email_unverified} =
               Admission.admit(org.id, Map.delete(claims("u@#{domain}"), "email_verified"))

      assert {:error, :no_email} = Admission.admit(org.id, %{"email_verified" => true})
    end

    test "verifying needs the record: no record, an error and no stamp", %{org: org} do
      row = CMS.add_site_sso_domain!(F.unique_domain("verify"), tenant: org, authorize?: false)

      assert {:error, error} = CMS.verify_site_sso_domain(row, tenant: org, authorize?: false)
      assert Exception.message(error) =~ "_kiln-sso.#{row.domain}"

      F.publish!(row)

      assert %{verified_at: %DateTime{}} =
               CMS.verify_site_sso_domain!(row, tenant: org, authorize?: false)
    end

    test "the token is generated, never taken from input, and domains are normalised",
         %{org: org} do
      row =
        CMS.add_site_sso_domain!("  Example-#{System.unique_integer([:positive])}.COM. ",
          tenant: org,
          authorize?: false
        )

      assert row.domain =~ ~r/\Aexample-\d+\.com\z/
      assert byte_size(row.verification_token) >= 32
      assert is_nil(row.verified_at)

      for bad <- ["localhost", "user@example.com", "https://example.com", "com"] do
        assert {:error, _} = CMS.add_site_sso_domain(bad, tenant: org, authorize?: false)
      end
    end
  end

  describe "cross-site isolation" do
    test "site A's provider cannot sign in a site-B admin", %{
      org: org,
      other: other,
      domain: domain
    } do
      b_admin = user!("boss@#{domain}")
      member!(b_admin, other, :admin)

      assert {:error, :access_elsewhere} = Admission.admit(org.id, claims("boss@#{domain}"))
    end

    test "nor through the real flow: no token is minted for the site-B admin",
         %{org: org, other: other, domain: domain, key: key} do
      b_admin = user!("boss2@#{domain}")
      member!(b_admin, other, :admin)

      before = token_count(b_admin)
      assert {{:error, :access_elsewhere}, _url} = full_flow(org, key, claims("boss2@#{domain}"))
      assert token_count(b_admin) == before
    end

    test "any membership elsewhere refuses, even a viewer's", %{
      org: org,
      other: other,
      domain: domain
    } do
      reader = user!("reader@#{domain}")
      member!(reader, org, :editor)
      member!(reader, other, :viewer)

      assert {:error, :access_elsewhere} = Admission.admit(org.id, claims("reader@#{domain}"))
    end

    test "a platform admin is refused, by standing role or by a live temporary grant",
         %{org: org, domain: domain} do
      user!("root@#{domain}", %{role: :admin})
      assert {:error, :access_elsewhere} = Admission.admit(org.id, claims("root@#{domain}"))

      user!("temp@#{domain}", %{
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

      assert {:error, :access_elsewhere} = Admission.admit(org.id, claims("temp@#{domain}"))
    end

    test "a membership-less global editor holds the default org, so another site may not",
         %{org: org, domain: domain} do
      user!("legacy@#{domain}", %{role: :editor})
      assert {:error, :access_elsewhere} = Admission.admit(org.id, claims("legacy@#{domain}"))
    end

    test "membership-less legacy audiences apply everywhere, so they refuse too",
         %{org: org, domain: domain} do
      user!("paid@#{domain}", %{audiences: [:member]})
      assert {:error, :access_elsewhere} = Admission.admit(org.id, claims("paid@#{domain}"))
    end

    test "an account whose only access is on this site is admitted, as-is",
         %{org: org, domain: domain} do
      editor = user!("editor@#{domain}", %{name: "Kept Name"})
      member!(editor, org, :admin)

      assert {:ok, signed_in} =
               Admission.admit(org.id, claims("editor@#{domain}", %{"name" => "IdP Name"}))

      assert signed_in.id == editor.id
      assert signed_in.name == "Kept Name"
      assert is_binary(signed_in.__metadata__.token)
    end

    test "an unconfirmed account is refused rather than handed to the provider's user",
         %{org: org, domain: domain} do
      user!("pre@#{domain}", %{confirmed_at: nil})
      assert {:error, :unconfirmed_account} = Admission.admit(org.id, claims("pre@#{domain}"))
    end

    test "invite-only: no new accounts, known ones still sign in", %{org: org, domain: domain} do
      previous = Application.get_env(:kiln_cms, :registration_enabled)
      Application.put_env(:kiln_cms, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:kiln_cms, :registration_enabled),
          else: Application.put_env(:kiln_cms, :registration_enabled, previous)
      end)

      assert {:error, :registration_disabled} = Admission.admit(org.id, claims("new@#{domain}"))

      known = user!("known@#{domain}")
      member!(known, org, :viewer)
      assert {:ok, _user} = Admission.admit(org.id, claims("known@#{domain}"))
    end
  end

  describe "the system-only actions" do
    test "an actor cannot mint a site sign-in token, even a platform admin", %{domain: domain} do
      admin = user!("op-#{System.unique_integer([:positive])}@example.com", %{role: :admin})
      target = user!("target@#{domain}")

      assert {:ok, nil} =
               Accounts.complete_site_sso_sign_in(target.id,
                 actor: admin,
                 not_found_error?: false
               )
    end

    test "an actor cannot provision through the site action", %{domain: domain} do
      admin = user!("op2-#{System.unique_integer([:positive])}@example.com", %{role: :admin})

      assert {:error, _} =
               Accounts.register_with_site_sso(%{email: "made@#{domain}"}, actor: admin)
    end
  end

  describe "SSRF" do
    test "a private, loopback, link-local or plain-HTTP issuer is refused at save", %{
      other: other
    } do
      for issuer <- [
            "https://127.0.0.1",
            "https://10.0.0.8/realms/x",
            "https://169.254.169.254",
            "https://localhost:8443",
            "https://idp.internal",
            "https://[::1]",
            "http://idp.example.test",
            "https://user:pw@idp.example.test"
          ] do
        assert {:error, error} =
                 CMS.save_site_sso_provider(
                   %{issuer: issuer, client_id: "c", client_secret: "s"},
                   tenant: other,
                   authorize?: false
                 ),
               "#{issuer} should be refused"

        assert Exception.message(error) =~ "issuer"
      end
    end

    test "a private issuer written past the validation is still refused at sign-in",
         %{org: org} do
      from(p in "site_sso_providers", where: p.org_id == type(^org.id, :binary_id))
      |> KilnCMS.Repo.update_all(set: [issuer: "https://169.254.169.254"])

      assert {:error, {:provider, "issuer refused: " <> _}} =
               SiteSso.authorize(org.id, @redirect_uri)
    end

    test "discovery naming a private key URL is refused before anything is dialled there",
         %{org: org, domain: domain, key: key} do
      assert {{:error, {:provider, reason}}, _url} =
               full_flow(org, key, claims("k@#{domain}"),
                 discovery: %{"jwks_uri" => "https://169.254.169.254/keys"}
               )

      assert inspect(reason) =~ "private or link-local"
    end

    test "discovery naming a plain-HTTP token endpoint is refused", %{org: org, key: key} do
      F.stub_provider!(key, %{},
        discovery: %{"token_endpoint" => "http://idp.example.test/token"}
      )

      assert {:error, {:provider, "token_endpoint must be https://"}} =
               SiteSso.authorize(org.id, @redirect_uri)
    end
  end

  describe "fail direction and the sign-in option" do
    test "a usable provider with a verified domain is offered with its label", %{org: org} do
      assert {:ok, "Acme staff"} = SiteSso.sign_in_option(org)
    end

    test "no row, a row switched off, or no verified domain offers nothing", %{other: other} do
      assert SiteSso.sign_in_option(other) == nil

      F.provider!(other, %{enabled: false})
      assert SiteSso.sign_in_option(other) == nil

      {:ok, [row]} = CMS.list_site_sso_provider(tenant: other, authorize?: false)
      CMS.update_site_sso_provider!(row, %{enabled: true}, tenant: other, authorize?: false)
      assert SiteSso.sign_in_option(other) == nil
    end

    test "an undecryptable secret makes site SSO unavailable, never the operator's provider",
         %{org: org} do
      from(p in "site_sso_providers", where: p.org_id == type(^org.id, :binary_id))
      |> KilnCMS.Repo.update_all(set: [client_secret_encrypted: "not-ciphertext"])

      assert SiteSso.sign_in_option(org) == :unavailable
      assert {:error, :credentials_unreadable} = SiteSso.authorize(org.id, @redirect_uri)
    end
  end

  describe "the client secret" do
    test "is encrypted, kept on a blank save, and required when switched on", %{other: other} do
      row = F.provider!(other)
      assert row.client_secret_encrypted != F.client_secret()
      assert {:ok, secret} = KilnCMS.Keys.Vault.decrypt(row.client_secret_encrypted)
      assert secret == F.client_secret()

      kept =
        CMS.update_site_sso_provider!(row, %{client_id: "c2", client_secret: ""},
          tenant: other,
          authorize?: false
        )

      assert kept.client_secret_encrypted == row.client_secret_encrypted

      third = KilnCMS.OrgFixtures.org("sso-third")

      assert {:error, _} =
               CMS.save_site_sso_provider(%{issuer: F.issuer(), client_id: "c"},
                 tenant: third,
                 authorize?: false
               )
    end
  end

  describe "the operator's provider" do
    test "stays compiled and keeps reading its own config, whatever a site saves",
         %{org: org} do
      strategy = AshAuthentication.Info.strategy!(User, :sso)
      assert strategy.client_secret == {KilnCMS.Accounts.SsoSecrets, []}

      default = Accounts.default_org()
      F.provider!(default, %{issuer: "https://other-idp.example.test", client_id: "site-owned"})

      assert {:ok, "kiln-test-client"} =
               KilnCMS.Accounts.SsoSecrets.secret_for(
                 [:authentication, :strategies, :sso, :client_id],
                 User,
                 [],
                 %{}
               )

      assert {:ok, "https://idp.example.test"} =
               KilnCMS.Accounts.SsoSecrets.secret_for(
                 [:authentication, :strategies, :sso, :base_url],
                 User,
                 [],
                 %{}
               )

      assert SiteSso.sign_in_option(org) == {:ok, "Acme staff"}
    end

    test "a site sign-in writes no provider identity the operator's strategy could match",
         %{org: org, domain: domain} do
      {:ok, user} = Admission.admit(org.id, claims("ident@#{domain}", %{"sub" => "shared-sub"}))

      assert [] ==
               KilnCMS.Accounts.UserIdentity
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read!(authorize?: false)
    end
  end

  defp token_count(user) do
    subject = "user?id=#{user.id}"

    KilnCMS.Repo.one(from(t in "tokens", where: t.subject == ^subject, select: count()))
  end
end
