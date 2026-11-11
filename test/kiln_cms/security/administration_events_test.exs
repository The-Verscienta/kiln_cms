defmodule KilnCMS.Security.AdministrationEventsTest do
  @moduledoc """
  The administration half of the security audit log (#2241): role grants and
  revocations, time-boxed elevation, API keys, single sign-on configuration and
  site settings. Each emits from the action that does the work, in its
  transaction, with the actor, the org, the client address and an allowlisted
  metadata map that never carries a secret.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Security
  alias KilnCMS.Security.AuthEvents

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])
  defp default_org, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "adm-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # The context an admin LiveView passes: client address, user agent and org.
  defp ctx(org_id \\ nil) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> Plug.Conn.put_req_header("user-agent", "AuditTest/1.0")

    AuthEvents.context(conn, org_id || default_org())
  end

  # Every event of an org, oldest first, read as an admin of that org.
  defp events(org_id \\ nil, type \\ nil) do
    org_id = org_id || default_org()

    events =
      Security.list_events!(actor: user(:admin), tenant: org_id, page: [limit: 200])
      |> page_results()

    events = Enum.reverse(events)
    if type, do: Enum.filter(events, &(&1.type == type)), else: events
  end

  defp page_results(%{results: results}), do: results
  defp page_results(list) when is_list(list), do: list

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role
    })
  end

  defp assert_request(event) do
    assert event.ip == "203.0.113.7"
    assert event.user_agent == "AuditTest/1.0"
  end

  describe "role_granted / role_revoked on a user's standing role" do
    test "a raised role records who, whom, from what to what, and where from" do
      admin = user(:admin)
      subject = user(:editor)

      assert {:ok, _} =
               Accounts.manage_user_access(subject, %{role: :admin}, actor: admin, context: ctx())

      assert [event] = events(nil, :role_granted)
      assert event.actor_id == admin.id
      assert event.actor_label == to_string(admin.email)
      assert event.target_type == "user"
      assert event.target_id == subject.id
      assert event.org_id == default_org()

      assert event.metadata == %{
               "role" => "admin",
               "previous_role" => "editor",
               "level" => "platform"
             }

      assert_request(event)
    end

    test "a lowered role records role_revoked naming the role taken away" do
      admin = user(:admin)
      subject = user(:admin)

      assert {:ok, _} =
               Accounts.manage_user_access(subject, %{role: :viewer},
                 actor: admin,
                 context: ctx()
               )

      assert [event] = events(nil, :role_revoked)
      assert event.target_id == subject.id
      assert event.metadata == %{"role" => "admin", "level" => "platform", "change" => "demoted"}
      assert_request(event)
    end

    test "an edit that leaves the role alone records nothing" do
      admin = user(:admin)
      subject = user(:editor)

      assert {:ok, _} =
               Accounts.manage_user_access(subject, %{role: :editor, editable_types: ["post"]},
                 actor: admin,
                 context: ctx()
               )

      assert events() == []
    end

    test "without a request context the event still records, without an address" do
      admin = user(:admin)
      subject = user(:editor)

      assert {:ok, _} =
               Accounts.manage_user_access(subject, %{role: :admin},
                 actor: admin,
                 context: %{security_tenant: default_org()}
               )

      assert [event] = events(nil, :role_granted)
      assert event.actor_id == admin.id
      assert is_nil(event.ip)
      assert is_nil(event.user_agent)
    end

    test "an editor or viewer who is refused records nothing" do
      subject = user(:viewer)

      for role <- [:editor, :viewer] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.manage_user_access(subject, %{role: :admin},
                   actor: user(role),
                   context: ctx()
                 )
      end

      assert events() == []
    end

    test "rolls back with the action" do
      admin = user(:admin)
      subject = user(:editor)

      KilnCMS.Repo.transaction(fn ->
        {:ok, _} =
          Accounts.manage_user_access(subject, %{role: :admin}, actor: admin, context: ctx())

        assert [_] = events(nil, :role_granted)
        KilnCMS.Repo.rollback(:undo)
      end)

      assert events() == []
      assert Accounts.get_user!(subject.id, authorize?: false).role == :editor
    end
  end

  describe "role_granted / role_revoked on a membership" do
    test "a created membership is a grant, in the membership's own org" do
      other = org("adm-other")
      admin = user(:admin)
      subject = user(:viewer)

      assert {:ok, _} =
               Accounts.create_org_membership(
                 %{organization_id: other.id, user_id: subject.id, role: :editor},
                 actor: admin,
                 context: ctx(default_org())
               )

      assert [event] = events(other.id, :role_granted)
      assert event.target_id == subject.id
      assert event.metadata == %{"role" => "editor", "level" => "site"}
      assert event.org_id == other.id
      assert_request(event)

      # The acting admin's own org never sees another org's grant.
      assert events(default_org()) == []
    end

    test "raising and lowering the role, and an audience-only edit" do
      admin = user(:admin)
      subject = user(:viewer)
      membership = member!(subject, default_org(), :viewer)

      assert {:ok, membership} =
               Accounts.update_org_membership(membership, %{role: :editor},
                 actor: admin,
                 context: ctx()
               )

      assert [granted] = events(nil, :role_granted)

      assert granted.metadata == %{
               "role" => "editor",
               "previous_role" => "viewer",
               "level" => "site"
             }

      assert {:ok, membership} =
               Accounts.update_org_membership(membership, %{audiences: []},
                 actor: admin,
                 context: ctx()
               )

      assert length(events()) == 1

      assert {:ok, _} =
               Accounts.update_org_membership(membership, %{role: :viewer},
                 actor: admin,
                 context: ctx()
               )

      assert [revoked] = events(nil, :role_revoked)
      assert revoked.metadata == %{"role" => "editor", "level" => "site", "change" => "demoted"}
      assert revoked.target_id == subject.id
    end

    test "removing a membership revokes its role" do
      admin = user(:admin)
      subject = user(:editor)
      membership = member!(subject, default_org(), :editor)

      assert :ok = Accounts.remove_org_membership(membership, actor: admin, context: ctx())

      assert [event] = events(nil, :role_revoked)
      assert event.metadata == %{"role" => "editor", "level" => "site", "change" => "removed"}
      assert event.target_id == subject.id
      assert_request(event)
    end

    test "an editor refused the write records nothing" do
      subject = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.create_org_membership(
                 %{organization_id: default_org(), user_id: subject.id, role: :admin},
                 actor: user(:editor),
                 context: ctx()
               )

      assert events() == []
    end

    test "erasing the member writes no event" do
      admin = user(:admin)
      subject = user(:editor)
      member!(subject, default_org(), :editor)

      assert {:ok, _} = Accounts.anonymize_user(subject, actor: admin, context: ctx())

      assert events() == []
    end
  end

  describe "member_invited / invitation_revoked (#2135)" do
    test "an invitation, a resend and a revoke, in the invited site's log, never the address" do
      other = org("adm-invite")
      admin = user(:admin)
      email = "adm-invitee-#{uniq()}@example.com"

      invitation =
        Accounts.invite_to_org!(
          %{organization_id: other.id, email: email, role: :editor},
          actor: admin,
          context: ctx(default_org())
        )

      assert [invited] = events(other.id, :member_invited)
      assert invited.target_type == "invitation"
      assert invited.target_id == invitation.id
      assert invited.metadata == %{"role" => "editor", "resent" => false}
      assert_request(invited)

      Accounts.resend_invitation!(invitation, %{}, actor: admin, context: ctx(default_org()))
      assert [_, resent] = events(other.id, :member_invited)
      assert resent.metadata == %{"role" => "editor", "resent" => true}

      :ok = Accounts.revoke_invitation(invitation, actor: admin, context: ctx(default_org()))
      assert [revoked] = events(other.id, :invitation_revoked)
      assert revoked.metadata == %{"role" => "editor"}

      refute other.id |> events() |> inspect() |> String.contains?(email)
      assert events(default_org()) == []
    end

    test "an editor refused the invitation records nothing" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.invite_to_org(
                 %{organization_id: default_org(), email: "adm-refused-#{uniq()}@example.com"},
                 actor: user(:editor),
                 context: ctx()
               )

      assert events() == []
    end

    test "accepting records the role grant, with no person behind it" do
      admin = user(:admin)
      other = org("adm-accept")

      invitation =
        Accounts.invite_to_org!(
          %{organization_id: other.id, email: "adm-accept-#{uniq()}@example.com", role: :viewer},
          actor: admin
        )

      {:ok, user} =
        Accounts.register_with_invitation(
          %{
            token: invitation.__metadata__.token,
            password: "password123456",
            password_confirmation: "password123456"
          },
          authorize?: false,
          context: ctx(other.id)
        )

      assert [granted] = events(other.id, :role_granted)
      assert granted.target_id == user.id
      assert granted.actor_id == nil
      assert granted.metadata == %{"role" => "viewer", "level" => "site"}
    end
  end

  describe "elevation_granted" do
    test "a time-boxed grant on the account records the role and the minutes" do
      admin = user(:admin)
      subject = user(:editor)
      expires = DateTime.add(DateTime.utc_now(), 2, :hour)

      assert {:ok, _} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{granted_role: :admin, granted_role_expires_at: expires},
                 actor: admin,
                 context: ctx()
               )

      assert [event] = events(nil, :elevation_granted)
      assert event.actor_id == admin.id
      assert event.target_id == subject.id
      assert event.metadata["role"] == "admin"
      assert event.metadata["minutes"] in 119..120
      assert_request(event)
    end

    test "ending it early is a revocation of the elevated role" do
      admin = user(:admin)
      subject = user(:editor)
      expires = DateTime.add(DateTime.utc_now(), 2, :hour)

      {:ok, subject} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: expires},
          actor: admin,
          context: ctx()
        )

      assert {:ok, _} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{granted_role: nil, granted_role_expires_at: nil},
                 actor: admin,
                 context: ctx()
               )

      assert [event] = events(nil, :role_revoked)

      assert event.metadata == %{
               "role" => "admin",
               "level" => "platform",
               "change" => "grant_revoked"
             }
    end

    test "the membership twin records in its own org" do
      other = org("adm-elev")
      admin = user(:admin)
      subject = user(:editor)
      membership = member!(subject, other.id, :editor)
      expires = DateTime.add(DateTime.utc_now(), 90, :minute)

      assert {:ok, _} =
               Accounts.grant_membership_temporary_role(
                 membership,
                 %{granted_role: :admin, granted_role_expires_at: expires},
                 actor: admin,
                 context: ctx()
               )

      assert [event] = events(other.id, :elevation_granted)
      assert event.metadata["role"] == "admin"
      assert event.target_id == subject.id
      assert events(default_org()) == []
    end

    test "a refused editor records nothing" do
      subject = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{
                   granted_role: :admin,
                   granted_role_expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
                 },
                 actor: user(:editor),
                 context: ctx()
               )

      assert events() == []
    end

    test "the expiry sweep records nothing" do
      subject = user(:editor)
      expires = DateTime.add(DateTime.utc_now(), 1, :hour)

      {:ok, subject} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: expires},
          actor: user(:admin),
          context: ctx()
        )

      before = length(events())

      assert {:ok, _} =
               Accounts.expire_user_role_grant(subject, authorize?: false, context: ctx())

      assert length(events()) == before
    end
  end

  describe "api_key_created / api_key_revoked" do
    test "minting records the name and scope, never the key or its hash" do
      admin = user(:admin)
      owner = user(:editor)
      expires = DateTime.add(DateTime.utc_now(), 30, :day)

      assert {:ok, key} =
               Accounts.mint_api_key(owner.id, "ci robot", expires, %{access: :read_write},
                 actor: admin,
                 context: ctx()
               )

      assert [event] = events(nil, :api_key_created)
      assert event.actor_id == admin.id
      assert event.target_type == "api_key"
      assert event.target_id == key.id
      assert event.metadata == %{"name" => "ci robot", "scope" => "read_write"}
      assert_request(event)

      plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)
      dump = inspect(event, limit: :infinity)
      refute dump =~ plaintext
      refute dump =~ Base.encode64(key.api_key_hash)
      refute dump =~ Base.encode16(key.api_key_hash, case: :lower)
    end

    test "revoking records once; a repeat revoke records nothing more" do
      admin = user(:admin)
      expires = DateTime.add(DateTime.utc_now(), 30, :day)

      {:ok, key} =
        Accounts.mint_api_key(user(:viewer).id, "old", expires, %{}, actor: admin, context: ctx())

      assert {:ok, key} = Accounts.revoke_api_key(key, actor: admin, context: ctx())
      assert [event] = events(nil, :api_key_revoked)
      assert event.target_id == key.id
      assert event.metadata == %{"name" => "old"}
      assert_request(event)

      assert {:ok, _} = Accounts.revoke_api_key(key, actor: admin, context: ctx())
      assert length(events(nil, :api_key_revoked)) == 1
    end

    test "a refused editor or viewer records nothing" do
      expires = DateTime.add(DateTime.utc_now(), 30, :day)
      owner = user(:viewer)

      for role <- [:editor, :viewer] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.mint_api_key(owner.id, "nope", expires, %{},
                   actor: user(role),
                   context: ctx()
                 )
      end

      assert events() == []
    end

    test "rotating records the new key and the retired one, from the same request" do
      admin = user(:admin)
      owner = user(:viewer)
      until = DateTime.add(DateTime.utc_now(), 90, :day)
      expires = DateTime.add(DateTime.utc_now(), 7, :day)

      {:ok, key} =
        Accounts.mint_api_key(
          owner.id,
          "svc",
          expires,
          %{access: :draft_write, rotatable_until: until},
          actor: admin,
          context: ctx()
        )

      {:ok, actor} =
        Accounts.actor_from_api_key(Ash.Resource.get_metadata(key, :plaintext_api_key))

      assert {:ok, new} = Accounts.rotate_api_key(actor: actor, context: ctx())

      assert [_minted, rotated] = events(nil, :api_key_created)
      assert rotated.target_id == new.id
      assert rotated.metadata == %{"name" => "svc", "scope" => "draft_write", "via" => "rotate"}
      assert rotated.actor_id == owner.id
      assert_request(rotated)

      assert [retired] = events(nil, :api_key_revoked)
      assert retired.target_id == key.id
      assert_request(retired)
    end

    test "rolls back with the action" do
      admin = user(:admin)
      expires = DateTime.add(DateTime.utc_now(), 30, :day)

      KilnCMS.Repo.transaction(fn ->
        {:ok, _} =
          Accounts.mint_api_key(user(:viewer).id, "x", expires, %{}, actor: admin, context: ctx())

        assert [_] = events(nil, :api_key_created)
        KilnCMS.Repo.rollback(:undo)
      end)

      assert events() == []
    end
  end

  describe "sso_config_changed" do
    test "the provider: created, updated, removed, and never the issuer or secret" do
      admin = user(:admin)
      opts = [actor: admin, tenant: default_org(), context: ctx()]

      assert {:ok, row} =
               CMS.save_site_sso_provider(
                 %{
                   issuer: "https://idp.example.test",
                   client_id: "client-abc",
                   client_secret: "super-secret-value",
                   label: "Acme"
                 },
                 opts
               )

      assert {:ok, row} = CMS.update_site_sso_provider(row, %{enabled: false}, opts)
      assert :ok = CMS.reset_site_sso_provider(row, opts)

      assert [created, updated, removed] = events(nil, :sso_config_changed)

      assert Enum.map([created, updated, removed], & &1.metadata["change"]) ==
               ["created", "updated", "removed"]

      for event <- [created, updated, removed] do
        assert event.metadata["provider"] == "site_oidc"
        assert event.actor_id == admin.id
        assert_request(event)
        dump = inspect(event, limit: :infinity)
        refute dump =~ "super-secret-value"
        refute dump =~ "client-abc"
        refute dump =~ "idp.example.test"
      end

      assert events(nil, :org_setting_changed) == []
    end

    test "a verified-domain list: added, verified, removed" do
      admin = user(:admin)
      opts = [actor: admin, tenant: default_org(), context: ctx()]

      domain = "acme-#{uniq()}.sso-corp.test"
      assert {:ok, row} = CMS.add_site_sso_domain(domain, opts)
      KilnCMS.SiteSsoFixtures.publish!(row)
      assert {:ok, row} = CMS.verify_site_sso_domain(row, opts)
      assert :ok = CMS.remove_site_sso_domain(row, opts)

      assert [added, verified, removed] = events(nil, :sso_config_changed)
      assert added.metadata == %{"provider" => "site_sso_domain", "change" => "created"}
      assert verified.metadata["change"] == "updated"
      assert removed.metadata["change"] == "removed"
      refute inspect([added, verified, removed]) =~ "sso-corp"
    end

    test "an editor refused the write records nothing" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_sso_provider(
                 %{issuer: "https://idp.example.test", client_id: "c", client_secret: "s3cret"},
                 actor: user(:editor),
                 tenant: default_org(),
                 context: ctx()
               )

      assert events() == []
    end

    test "another org's admin never sees them" do
      other = org("adm-sso")
      admin = user(:admin)

      assert {:ok, _} =
               CMS.save_site_sso_provider(
                 %{issuer: "https://idp.example.test", client_id: "c", client_secret: "s3cret"},
                 actor: admin,
                 tenant: default_org(),
                 context: ctx()
               )

      assert length(events(nil, :sso_config_changed)) == 1
      assert events(other.id) == []
    end
  end

  describe "org_setting_changed" do
    test "a setting save and reset record the setting's name and no values" do
      admin = user(:admin)
      opts = [actor: admin, tenant: default_org(), context: ctx()]

      assert {:ok, row} =
               CMS.save_site_code_injection(
                 %{head_html: "<script>secret-token-123</script>"},
                 opts
               )

      assert :ok = CMS.reset_site_code_injection(row, opts)

      assert [saved, reset] = events(nil, :org_setting_changed)
      assert saved.metadata == %{"setting" => "site_code_injection"}
      assert reset.metadata == %{"setting" => "site_code_injection"}
      assert saved.actor_id == admin.id
      assert saved.target_type == "site_code_injection"
      assert_request(saved)
      refute inspect(saved, limit: :infinity) =~ "secret-token-123"
    end

    test "the log's own retention window is audited" do
      admin = user(:admin)

      assert {:ok, _} =
               Security.set_retention_days(90,
                 actor: admin,
                 tenant: default_org(),
                 context: ctx()
               )

      assert [event] = events(nil, :org_setting_changed)
      assert event.metadata == %{"setting" => "site_security_log"}
    end

    test "an IP block rule is audited on create and removal" do
      admin = user(:admin)

      opts = [
        actor: admin,
        tenant: default_org(),
        context: Map.put(ctx(), :client_ip, {198, 51, 100, 1})
      ]

      assert {:ok, rule} = CMS.create_ip_block_rule(%{cidr: "192.0.2.0/24"}, opts)
      assert :ok = CMS.destroy_ip_block_rule(rule, opts)

      assert [created, removed] = events(nil, :org_setting_changed)
      assert created.metadata == %{"setting" => "ip_block_rule"}
      assert removed.metadata == %{"setting" => "ip_block_rule"}
      refute inspect([created, removed]) =~ "192.0.2"
    end

    test "a write by the system, with no person behind it, is not an event" do
      assert {:ok, _} =
               CMS.save_site_code_injection(%{head_html: "<b>x</b>"},
                 authorize?: false,
                 tenant: default_org()
               )

      assert events() == []
    end

    test "a refused editor records nothing" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_code_injection(%{head_html: "<b>x</b>"},
                 actor: user(:editor),
                 tenant: default_org(),
                 context: ctx()
               )

      assert events() == []
    end

    test "rolls back with the setting" do
      admin = user(:admin)

      KilnCMS.Repo.transaction(fn ->
        {:ok, _} =
          CMS.save_site_code_injection(%{head_html: "<b>x</b>"},
            actor: admin,
            tenant: default_org(),
            context: ctx()
          )

        assert [_] = events(nil, :org_setting_changed)
        KilnCMS.Repo.rollback(:undo)
      end)

      assert events() == []
    end

    test "each org sees only its own" do
      other = org("adm-setting")
      admin = user(:admin)

      assert {:ok, _} =
               CMS.save_site_code_injection(%{head_html: "<b>x</b>"},
                 actor: admin,
                 tenant: other.id,
                 context: ctx(other.id)
               )

      assert length(events(other.id)) == 1
      assert events(default_org()) == []
    end
  end

  describe "the metadata security alerts read (#2245)" do
    test "removing a member whose admin tier is a live grant records the admin tier taken" do
      admin = user(:admin)
      subject = user(:editor)
      membership = member!(subject, default_org(), :editor)
      expires = DateTime.add(DateTime.utc_now(), 2, :hour)

      {:ok, membership} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: :admin, granted_role_expires_at: expires},
          actor: admin,
          context: ctx()
        )

      [granted] = events(nil, :elevation_granted)
      assert granted.metadata["level"] == "site"
      refute Map.has_key?(granted.metadata, "via")

      assert :ok = Accounts.remove_org_membership(membership, actor: admin, context: ctx())

      assert [event] = events(nil, :role_revoked)
      assert event.metadata == %{"role" => "admin", "level" => "site", "change" => "removed"}
    end

    test "carrying a legacy account onto the default org is marked, grant included" do
      admin = user(:admin)
      expires = DateTime.add(DateTime.utc_now(), 2, :hour)

      legacy =
        Ash.Seed.seed!(Accounts.User, %{
          email: "legacy-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor,
          granted_role: :admin,
          granted_role_expires_at: expires
        })

      assert {:ok, _membership} =
               Accounts.LegacyAffiliation.ensure_default_membership(legacy,
                 actor: admin,
                 context: ctx()
               )

      assert [granted] = events(nil, :role_granted)
      assert granted.metadata == %{"role" => "editor", "level" => "site", "via" => "legacy_carry"}

      assert [elevation] = events(nil, :elevation_granted)
      assert elevation.metadata["via"] == "legacy_carry"
      assert elevation.metadata["role"] == "admin"
    end
  end
end
