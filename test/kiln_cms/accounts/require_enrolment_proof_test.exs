defmodule KilnCMS.Accounts.RequireEnrolmentProofTest do
  @moduledoc """
  The email proof enforced on the actions themselves (#2247, owner decision
  1b; `KilnCMS.Accounts.Changes.RequireEnrolmentProof`): `User.:confirm_totp`
  and `Passkey.:register` refuse a password session past the site's deadline
  that has not proved the account's email, whatever the page did. What each
  enrolment was vouched by is recorded as the event's `proof`.

  Every account here is a viewer on a fresh site that requires everyone with
  no grace, created long before, so it is held now.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PasskeyFixtures, only: [b64: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.EnrolmentProof
  alias KilnCMS.Accounts.Errors.EnrolmentProofRequired
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  setup do
    site = org("rep")

    Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
      org_id: site.id,
      required_for: :everyone,
      grace_days: 0,
      admin_required_since: @long_ago,
      editor_required_since: @long_ago,
      viewer_required_since: @long_ago,
      policy_changed_at: @long_ago
    })

    KilnCMS.Cache.bust_second_factor_policy(site.id)
    %{site: site}
  end

  defp held_viewer(site, attrs \\ %{}) do
    user =
      Ash.Seed.seed!(
        Accounts.User,
        Map.merge(
          %{
            email: "rep-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now(),
            role: :viewer,
            inserted_at: @long_ago
          },
          attrs
        )
      )

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: :viewer,
      inserted_at: @long_ago
    })

    user
  end

  defp session(method, jti \\ nil),
    do: %{
      jti: jti || "jti-#{System.unique_integer([:positive])}",
      method: method,
      signed_in_at: DateTime.utc_now()
    }

  # Stage a secret and confirm it with a current code, with `context`. The
  # event needs a site to be recorded on: the user's own.
  defp confirm(user, context, args \\ %{}) do
    {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)
    code = Totp.code_at(staged.totp_pending_secret, System.system_time(:second))

    Accounts.confirm_totp(staged, Map.merge(%{code: code}, args),
      actor: staged,
      context: on_site(context, user)
    )
  end

  defp on_site(context, user) do
    site_id =
      case Accounts.list_memberships_for_user!(user.id, actor: user) do
        [membership | _] -> membership.organization_id
        [] -> Accounts.default_org_id()
      end

    Map.put(context, KilnCMS.Security.Recorder.tenant_key(), site_id)
  end

  defp register_passkey(user, context) do
    WebAuthn.register_passkey(
      user,
      WebAuthn.registration_challenge(),
      %{
        "attestation_object" => b64("rep-cred-#{System.unique_integer([:positive])}"),
        "client_data_json" => b64(~s({"type":"webauthn.create"}))
      },
      context: on_site(context, user)
    )
  end

  # A real proof: mail a code (through the operator's test relay) and verify it.
  defp prove(user, site, session) do
    {:ok, pending} = EnrolmentProof.send_code(user, site.id, session)
    {:ok, proof} = EnrolmentProof.verify(user, session, emailed_code(user), pending)
    proof
  end

  defp emailed_code(user) do
    address = to_string(user.email)

    assert_email_sent(fn email ->
      assert [{_name, ^address}] = email.to
      send(self(), {:code, code_in(email)})
      true
    end)

    assert_received {:code, code}
    code
  end

  defp code_in(email) do
    [_, code] = Regex.run(~r/<strong>(\d{6})<\/strong>/, email.html_body)
    code
  end

  defp refused?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%EnrolmentProofRequired{}, &1))

  defp refused?(_result), do: false

  defp proof_recorded(user, type) do
    KilnCMS.Repo.all(
      from(e in "security_events",
        where: e.target_id == type(^user.id, :binary_id) and e.type == ^type,
        select: e.metadata
      )
    )
  end

  defp reload(user), do: Ash.get!(Accounts.User, user.id, authorize?: false)

  describe ":confirm_totp" do
    test "a held password session without the proof is refused", %{site: site} do
      user = held_viewer(site)
      context = EnrolmentProof.context(site, session("password"), nil)

      assert refused?(confirm(user, context))
      assert is_nil(reload(user).totp_confirmed_at)
      assert proof_recorded(user, "second_factor_enrolled") == []
    end

    test "with the emailed proof it enrolls, and records how", %{site: site} do
      user = held_viewer(site)
      session = session("password")
      proof = prove(user, site, session)

      assert {:ok, _user} = confirm(user, EnrolmentProof.context(site, session, proof))
      assert reload(user).totp_confirmed_at

      assert proof_recorded(user, "second_factor_enrolled") == [
               %{"kind" => "totp", "proof" => "email"}
             ]
    end

    test "a proof is bound to the session it was made in", %{site: site} do
      user = held_viewer(site)
      proof = prove(user, site, session("password", "jti-a"))

      assert refused?(
               confirm(user, EnrolmentProof.context(site, session("password", "jti-b"), proof))
             )
    end

    test "a proof is bound to the account it was made for", %{site: site} do
      user = held_viewer(site)
      other = held_viewer(site)
      session = session("password")
      proof = prove(other, site, session)

      assert refused?(confirm(user, EnrolmentProof.context(site, session, proof)))
    end

    test "a forged or tampered proof is refused", %{site: site} do
      user = held_viewer(site)
      session = session("password")

      forged =
        Phoenix.Token.sign(KilnCMSWeb.Endpoint, "some other salt", %{
          "u" => user.id,
          "j" => session.jti
        })

      assert refused?(confirm(user, EnrolmentProof.context(site, session, forged)))
      assert refused?(confirm(user, EnrolmentProof.context(site, session, "not-a-token")))
    end

    test "a claimed skip is refused while the site's mail works", %{site: site} do
      user = held_viewer(site)

      assert refused?(confirm(user, EnrolmentProof.context(site, session("password"), :no_relay)))
    end

    test "a remember-me session, and one with no marker, must prove too", %{site: site} do
      user = held_viewer(site)

      assert refused?(confirm(user, EnrolmentProof.context(site, session("remember_me"), nil)))

      unmarked = %{jti: "jti-unmarked", method: nil, signed_in_at: nil}
      assert refused?(confirm(user, EnrolmentProof.context(site, unmarked, nil)))
      assert refused?(confirm(user, EnrolmentProof.context(site, nil, nil)))
    end

    test "magic-link, reset, confirmation and SSO sessions are not asked", %{site: site} do
      for {method, label} <- [
            {"magic_link", "magic_link_session"},
            {"password_reset", "magic_link_session"},
            {"confirm_new_user", "magic_link_session"},
            {"sso", "not_required"}
          ] do
        user = held_viewer(site)

        assert {:ok, _user} = confirm(user, EnrolmentProof.context(site, session(method), nil)),
               method

        assert proof_recorded(user, "second_factor_enrolled") ==
                 [%{"kind" => "totp", "proof" => label}]
      end
    end

    test "a password session from before the deadline is not asked", %{site: site} do
      user = held_viewer(site)
      before = %{session("password") | signed_in_at: ~U[2025-12-01 00:00:00Z]}

      assert {:ok, _user} = confirm(user, EnrolmentProof.context(site, before, nil))
    end

    test "replacing the authenticator after a recovery-code sign-in needs no proof", %{
      site: site
    } do
      {user, _secret} =
        TwoFactorFixtures.enabled_user(role: :viewer, inserted_at: @long_ago)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: site.id,
        user_id: user.id,
        role: :viewer,
        inserted_at: @long_ago
      })

      context = EnrolmentProof.context(site, session("password"), nil)

      assert {:ok, _user} = confirm(user, context, %{recovery_login?: true})

      assert proof_recorded(user, "second_factor_enrolled") ==
               [%{"kind" => "totp", "proof" => "not_required"}]
    end

    test "without the context, a held account is refused", %{site: site} do
      user = held_viewer(site)

      assert refused?(confirm(user, %{}))
    end

    test "without the context, an account no site holds is not", _ctx do
      user = KilnCMS.PasskeyFixtures.passkey_user(:viewer)

      assert {:ok, _user} = confirm(user, %{})
      assert proof_recorded(user, "second_factor_enrolled") == [%{"kind" => "totp"}]
    end

    test "the explicit system marker skips it", %{site: site} do
      user = held_viewer(site)

      assert {:ok, _user} = confirm(user, %{second_factor_enrolment: :system})
    end
  end

  describe "Passkey :register" do
    test "a held password session without the proof is refused", %{site: site} do
      user = held_viewer(site)

      assert refused?(
               register_passkey(user, EnrolmentProof.context(site, session("password"), nil))
             )

      assert WebAuthn.list(user) == []
    end

    test "with the emailed proof it registers, and records how", %{site: site} do
      user = held_viewer(site)
      session = session("password")
      proof = prove(user, site, session)

      assert {:ok, _passkey} =
               register_passkey(user, EnrolmentProof.context(site, session, proof))

      assert [%{"proof" => "email"}] = proof_recorded(user, "passkey_added")
    end

    test "without the context, a held account is refused", %{site: site} do
      assert refused?(register_passkey(held_viewer(site), %{}))
    end
  end
end
