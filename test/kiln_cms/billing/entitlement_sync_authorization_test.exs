defmodule KilnCMS.Billing.EntitlementSyncAuthorizationTest do
  @moduledoc """
  What the billing loop and the newsletter tier sync are *authorized* to do,
  now that they run as `%KilnCMS.SystemActor{}` instead of `authorize?: false`
  (#1402).

  These are the last two of the four modules #1329 audited but could not
  convert. The actions involved were already closed to every person — most of
  them `forbid_if always()`, admin included — so what changes is only that the
  one caller who may take them is named in the policy block. The tests pin both
  halves: the system actor may, and nobody else still may.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Billing
  alias KilnCMS.Newsletter
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])

  defp org_id, do: Accounts.default_org_id()

  defp billing_system, do: SystemActor.new(:billing)

  defp newsletter_system, do: SystemActor.new(:newsletter)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "esa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp tier do
    Ash.Seed.seed!(KilnCMS.Billing.MembershipTier, %{
      org_id: org_id(),
      name: "Tier #{uniq()}",
      slug: "esa-tier-#{uniq()}",
      audience: hd(KilnCMS.CMS.Audiences.gated()),
      provider_price_id: "price_#{uniq()}"
    })
  end

  defp membership(user, tier \\ nil) do
    tier = tier || tier()

    Ash.Seed.seed!(KilnCMS.Billing.Membership, %{
      org_id: org_id(),
      user_id: user.id,
      tier_id: tier.id,
      status: :active
    })
  end

  defp membership_event(membership) do
    Ash.Seed.seed!(KilnCMS.Billing.MembershipEvent, %{
      org_id: org_id(),
      membership_id: membership.id,
      user_id: membership.user_id,
      actor_id: membership.user_id,
      kind: :activated,
      to_status: :active
    })
  end

  defp segment do
    Ash.Seed.seed!(Newsletter.Segment, %{
      org_id: org_id(),
      name: "Segment #{uniq()}",
      slug: "esa-#{uniq()}"
    })
  end

  defp subscriber do
    Ash.Seed.seed!(Newsletter.Subscriber, %{
      org_id: org_id(),
      email: "sub-#{uniq()}@example.com",
      status: :confirmed
    })
  end

  describe "Billing.Settings — the singleton the checkout path reads" do
    test "the system actor reads it; an org admin does not" do
      # Asserting on the ROW, not on `{:ok, _}`: this is a filter policy, so a
      # refused read comes back `{:ok, []}` and a shape-only assertion would
      # pass with the grant removed.
      settings = Billing.ensure_settings!()

      ids = billing_system() |> then(&Billing.list_settings!(actor: &1)) |> Enum.map(& &1.id)

      assert settings.id in ids

      # Platform-admin only, NOT a per-org tier — that distinction is what the
      # resource's own comment is about, and it must survive the conversion.
      assert Billing.list_settings!(actor: user(:editor)) == []
    end

    test "it may not write the credentials" do
      settings = Billing.ensure_settings!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(settings, %{key: :secret_key, value: "sk_test"},
                 action: :store_secret,
                 actor: billing_system()
               )
    end
  end

  describe "Billing.Membership — read for the sync, anonymize for erasure" do
    test "the system actor reads a membership it is syncing" do
      member = user(:viewer)
      row = membership(member)

      ids =
        member.id
        |> Billing.memberships_for_export!(actor: billing_system())
        |> Enum.map(& &1.id)

      assert row.id in ids
    end

    test "an unrelated person still reads nothing" do
      member = user(:viewer)
      _row = membership(member)

      assert Billing.memberships_for_export!(member.id, actor: user(:viewer)) == []
    end

    test "GDPR erasure may anonymize; no person may, admin included" do
      row = membership(user(:viewer))

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(row, %{}, action: :anonymize, actor: user(:admin), tenant: org_id())

      assert {:ok, _anonymized} =
               Ash.update(row, %{}, action: :anonymize, actor: billing_system(), tenant: org_id())
    end
  end

  describe "Billing.MembershipEvent — the append-only entitlement trail" do
    test "no person may write one, admin included" do
      row = membership_event(membership(user(:viewer)))

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(row, %{},
                 action: :anonymize_actor,
                 actor: user(:admin),
                 tenant: org_id()
               )
    end

    test "GDPR erasure may redact the acting admin" do
      row = membership_event(membership(user(:viewer)))

      assert {:ok, redacted} =
               Ash.update(row, %{},
                 action: :anonymize_actor,
                 actor: billing_system(),
                 tenant: org_id()
               )

      assert is_nil(redacted.actor_id)
    end
  end

  describe "Newsletter — the tier-backed lifecycle is driven by billing" do
    test "no person may create a tier segment, admin included" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.create_tier_segment(
                 Ash.UUID.generate(),
                 :member,
                 %{name: "Tier", slug: "tier-esa-#{uniq()}"},
                 actor: user(:admin),
                 tenant: org_id()
               )
    end

    test "the sync may create one" do
      tier = tier()

      assert {:ok, %{managed_by: :tier}} =
               Newsletter.create_tier_segment(
                 tier.id,
                 :member,
                 %{name: "Tier", slug: "tier-esa-#{uniq()}"},
                 actor: newsletter_system(),
                 tenant: org_id()
               )
    end

    test "no person may link a member subscriber, admin included" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.link_member_subscriber(
                 user(:viewer).id,
                 %{email: "esa-link-#{uniq()}@example.com", name: "Member"},
                 actor: user(:admin),
                 tenant: org_id()
               )
    end

    test "the sync may link one" do
      member = user(:viewer)

      assert {:ok, %{user_id: user_id}} =
               Newsletter.link_member_subscriber(
                 member.id,
                 %{email: "esa-link-#{uniq()}@example.com", name: "Member"},
                 actor: newsletter_system(),
                 tenant: org_id()
               )

      assert user_id == member.id
    end

    test "the sync maintains the join rows; an editor cannot" do
      segment = segment()
      subscriber = subscriber()

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.add_to_segment(
                 %{segment_id: segment.id, subscriber_id: subscriber.id},
                 actor: user(:editor),
                 tenant: org_id()
               )

      assert {:ok, row} =
               Newsletter.add_to_segment(
                 %{segment_id: segment.id, subscriber_id: subscriber.id},
                 actor: newsletter_system(),
                 tenant: org_id()
               )

      assert :ok =
               Newsletter.remove_from_segment(row, actor: newsletter_system(), tenant: org_id())
    end
  end

  describe "what these actors deliberately cannot do" do
    test "neither reads the user table — which is why `get_user` keeps its bypass" do
      assert {:ok, []} = Ash.read(KilnCMS.Accounts.User, actor: billing_system())
      assert {:ok, []} = Ash.read(KilnCMS.Accounts.User, actor: newsletter_system())
    end

    test "neither reads content" do
      draft =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Unpublished",
          slug: "esa-draft-#{uniq()}",
          locale: "en",
          state: :draft
        })

      assert {:ok, []} =
               KilnCMS.CMS.Page
               |> Ash.Query.filter(id == ^draft.id)
               |> Ash.read(actor: newsletter_system(), tenant: org_id())
    end
  end
end
