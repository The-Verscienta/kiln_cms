defmodule KilnCMS.Billing.PrivacyTest do
  @moduledoc """
  The privacy surface for paid memberships (#337 Phase 2 × #212): GDPR export,
  erasure, and the staging scrub.

  Two properties carry the weight:

    * erasure must leave nothing that can **re-grant** access — a late webhook or
      the nightly reconcile would otherwise recompute entitlements for a
      tombstoned account;
    * the staging scrub must leave no **live external reference**, so a clone can
      never act on a real payment account.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp default_org_id, do: Accounts.default_org_id()

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "priv-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp admin do
    user(%{
      email: "priv-admin-#{System.unique_integer([:positive])}@example.com",
      role: :admin
    })
  end

  defp tier(org_id \\ nil) do
    Billing.create_tier!(
      %{
        name: "Supporter",
        slug: "supporter-#{System.unique_integer([:positive])}",
        audience: @gated,
        provider_price_id: "price_#{System.unique_integer([:positive])}"
      },
      authorize?: false,
      tenant: org_id || default_org_id()
    )
  end

  defp membership(u, t, attrs \\ %{}, org_id \\ nil) do
    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(
        %{
          org_id: org_id || default_org_id(),
          user_id: u.id,
          tier_id: t.id,
          status: :active,
          provider_customer_id: "cus_#{System.unique_integer([:positive])}",
          provider_subscription_id: "sub_#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  describe "GDPR export" do
    test "includes memberships with their provider identifiers" do
      # The ids are identifiers a subprocessor holds about this person, so
      # Art. 15/20 covers them — and they let the subject exercise rights
      # against the provider directly.
      u = user()
      m = membership(u, tier())

      export = Accounts.export_user_data(u)

      assert [entry] = export.memberships
      assert entry.status == :active
      assert entry.provider_customer_id == m.provider_customer_id
      assert entry.provider_subscription_id == m.provider_subscription_id
    end

    test "is empty for a user with no memberships" do
      assert Accounts.export_user_data(user()).memberships == []
    end

    test "spans organizations" do
      # The export answers "what do you hold about me" for the whole instance,
      # not just the host the request arrived on.
      other =
        Ash.Seed.seed!(Organization, %{
          name: "Other",
          slug: "o-#{System.unique_integer([:positive])}"
        })

      u = user()

      membership(u, tier())
      membership(u, tier(other.id), %{}, other.id)

      assert length(Accounts.export_user_data(u).memberships) == 2
    end

    test "carries no secret material" do
      u = user()
      membership(u, tier())

      refute inspect(Accounts.export_user_data(u)) =~ "sk_"
      refute inspect(Accounts.export_user_data(u)) =~ "whsec_"
    end
  end

  describe "erasure" do
    test "clears audiences — a tombstoned account keeps no access" do
      # This was a pre-existing gap: credentials were destroyed while access
      # survived. It matters more now a paid membership can grant an audience.
      u = user(%{audiences: [@gated]})

      {:ok, erased} = Accounts.anonymize_user(u, actor: admin())

      assert erased.audiences == []
    end

    test "cancels memberships and drops provider identifiers" do
      u = user()
      m = membership(u, tier())

      {:ok, _erased} = Accounts.anonymize_user(u, actor: admin())

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)

      assert reloaded.status == :canceled
      refute reloaded.provider_customer_id
      refute reloaded.provider_subscription_id
    end

    test "a recompute after erasure cannot re-grant" do
      # The property that matters: a late webhook or the nightly reconcile must
      # not resurrect entitlements for an erased account.
      u = user()
      membership(u, tier())

      {:ok, _delta} = Billing.Entitlements.recompute(u.id)
      {:ok, user} = Accounts.get_user(u.id, authorize?: false)
      assert user.audiences == [@gated]

      {:ok, _erased} = Accounts.anonymize_user(u, actor: admin())

      {:ok, _delta} = Billing.Entitlements.recompute(u.id)
      {:ok, after_erasure} = Accounts.get_user(u.id, authorize?: false)

      assert after_erasure.audiences == []
    end

    test "keeps the membership row so the audit trail stays intact" do
      u = user()
      m = membership(u, tier())

      {:ok, _erased} = Accounts.anonymize_user(u, actor: admin())

      assert {:ok, %{}} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
    end

    test "spans organizations" do
      other =
        Ash.Seed.seed!(Organization, %{
          name: "Other",
          slug: "o-#{System.unique_integer([:positive])}"
        })

      u = user()

      here = membership(u, tier())
      there = membership(u, tier(other.id), %{}, other.id)

      {:ok, _erased} = Accounts.anonymize_user(u, actor: admin())

      for m <- [here, there] do
        {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
        refute reloaded.provider_subscription_id
      end
    end

    test "the membership anonymize action is system-only" do
      u = user()
      m = membership(u, tier())

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.anonymize_membership_row(m, actor: admin(), tenant: m.org_id)
    end
  end

  describe "staging scrub" do
    setup do
      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_live_REAL", authorize?: false)

      {:ok, _settings} =
        Billing.store_billing_secret(settings, :webhook_secret, "whsec_REAL", authorize?: false)

      :ok
    end

    test "purges payment credentials" do
      assert Billing.configured?()

      KilnCMS.Staging.Scrub.run([])

      refute Billing.get_settings()
      refute Billing.configured?()
    end

    test "severs live provider references on memberships" do
      u = user()
      m = membership(u, tier())

      summary = KilnCMS.Staging.Scrub.run([])

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)

      refute reloaded.provider_customer_id
      refute reloaded.provider_subscription_id
      assert is_integer(summary.memberships_scrubbed)
    end

    test "deactivates tiers and tombstones their price pointers" do
      t = tier()

      KilnCMS.Staging.Scrub.run([])

      {:ok, reloaded} = Billing.get_tier(t.id, authorize?: false, tenant: default_org_id())

      refute reloaded.active
      refute reloaded.provider_price_id == t.provider_price_id
      assert reloaded.provider_price_id =~ "scrubbed_"
    end

    test "several tiers in one org do not collide on the unique price index" do
      # `provider_price_id` is NOT NULL with a per-org unique index, so the
      # tombstone has to be unique per row.
      tier()
      tier()

      assert %{tiers_deactivated: count} = KilnCMS.Staging.Scrub.run([])
      assert count >= 2
    end

    test "purges recorded webhook events — their payloads carry customer PII" do
      Billing.receive_webhook_event(
        %{
          provider: :stripe,
          provider_event_id: "evt_scrub_#{System.unique_integer([:positive])}",
          type: "checkout.session.completed",
          payload: %{"customer_email" => "real@example.com"}
        },
        authorize?: false
      )

      summary = KilnCMS.Staging.Scrub.run([])

      assert summary.billing_events_purged >= 1
      assert Billing.recent_webhook_events!(authorize?: false) == []
    end

    test "reports every new key in its summary" do
      summary = KilnCMS.Staging.Scrub.run([])

      for key <- [
            :billing_settings_purged,
            :billing_events_purged,
            :memberships_scrubbed,
            :tiers_deactivated
          ] do
        assert Map.has_key?(summary, key), "summary is missing #{key}"
      end
    end
  end
end
