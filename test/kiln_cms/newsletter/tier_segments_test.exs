defmodule KilnCMS.Newsletter.TierSegmentsTest do
  @moduledoc """
  Member-only newsletters (#337 Phase 2): tier-backed segments, the
  subscriber↔member link, and the relaxed send guard.

  `async: false` — these drive the billing entitlement recompute, which reads
  instance-wide tier state.

  The assertion that matters most is that a **hand-built** segment carrying the
  same `audience` label is still refused. That label has never been an access
  boundary, and this feature must not quietly turn it into one.
  """
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Newsletter

  @gated hd(Audiences.gated())

  defp org_id, do: Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "ts-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp member(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "ts-member-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp tier(attrs \\ %{}) do
    Billing.create_tier!(
      Map.merge(
        %{
          name: "Supporter",
          slug: "supporter-#{System.unique_integer([:positive])}",
          audience: @gated,
          provider_price_id: "price_#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      authorize?: false,
      tenant: org_id()
    )
  end

  defp tier_segment(tier) do
    Newsletter.list_segments!(authorize?: false, tenant: org_id())
    |> Enum.find(&(&1.tier_id == tier.id))
  end

  defp activate(user, tier) do
    m =
      Ash.Seed.seed!(Billing.Membership, %{
        org_id: org_id(),
        user_id: user.id,
        tier_id: tier.id,
        status: :incomplete
      })

    {:ok, updated} =
      Billing.apply_provider_state(m, %{status: :active}, authorize?: false, tenant: org_id())

    updated
  end

  defp gated_post do
    actor = admin()

    {:ok, post} =
      CMS.create_post(
        %{
          title: "Members piece",
          slug: "members-#{System.unique_integer([:positive])}",
          audience: @gated,
          blocks: [%{"_type" => "heading", "text" => "Body", "level" => 2}]
        },
        actor: actor,
        tenant: org_id()
      )

    {:ok, published} = CMS.publish_post(post, %{}, actor: actor, tenant: org_id())
    KilnCMS.DataCase.drain_oban()
    published
  end

  defp public_post do
    actor = admin()

    {:ok, post} =
      CMS.create_post(
        %{
          title: "Public piece",
          slug: "public-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "heading", "text" => "Body", "level" => 2}]
        },
        actor: actor,
        tenant: org_id()
      )

    {:ok, published} = CMS.publish_post(post, %{}, actor: actor, tenant: org_id())
    KilnCMS.DataCase.drain_oban()
    published
  end

  defp hand_built_segment(attrs \\ %{}) do
    Newsletter.create_segment!(
      Map.merge(
        %{name: "Curated", slug: "curated-#{System.unique_integer([:positive])}"},
        attrs
      ),
      authorize?: false,
      tenant: org_id()
    )
  end

  describe "tier segments are created automatically" do
    test "creating a tier creates its segment" do
      t = tier(%{name: "Patron"})

      assert segment = tier_segment(t)
      assert segment.managed_by == :tier
      assert segment.audience == @gated
      assert segment.slug == "tier-" <> t.slug
    end

    test "the segment's audience is derived from the tier, not hand-set" do
      t = tier()

      assert tier_segment(t).audience == t.audience
    end
  end

  describe "a managed segment refuses hand edits" do
    test "update is refused even for an admin" do
      t = tier()
      segment = tier_segment(t)

      assert {:error, error} =
               Newsletter.update_segment(segment, %{name: "Hijacked"}, actor: admin())

      assert Exception.message(error) =~ "maintained by its membership tier"
    end

    test "destroy is refused even for an admin" do
      t = tier()
      segment = tier_segment(t)

      assert {:error, _error} = Newsletter.destroy_segment(segment, actor: admin())
    end

    test "a hand-built segment is still editable" do
      segment = hand_built_segment()

      assert {:ok, updated} =
               Newsletter.update_segment(segment, %{name: "Renamed"}, actor: admin())

      assert updated.name == "Renamed"
    end

    test "for_tier is system-only" do
      t = tier()

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.create_tier_segment(
                 t.id,
                 @gated,
                 %{name: "X", slug: "x-#{System.unique_integer([:positive])}"},
                 actor: admin(),
                 tenant: org_id()
               )
    end
  end

  describe "membership activation syncs the segment" do
    test "an activating member joins their tier's segment" do
      u = member()
      t = tier()

      activate(u, t)

      assert [subscriber] = Newsletter.subscribers_for_user!(u.id, authorize?: false)
      assert subscriber.user_id == u.id

      segment = tier_segment(t)
      members = Newsletter.confirmed_subscribers!(segment.id, authorize?: false, tenant: org_id())
      # Pending, so not yet a recipient — but linked and on the list.
      assert members == []
    end

    test "a NEW subscriber lands :pending, not :confirmed" do
      # Paying for access is not consent to marketing email; this model is double
      # opt-in throughout. Flip `link_member`'s status if your policy differs.
      u = member()
      activate(u, tier())

      assert [subscriber] = Newsletter.subscribers_for_user!(u.id, authorize?: false)
      assert subscriber.status == :pending
    end

    test "an UNSUBSCRIBED person is linked but NOT resurrected" do
      # The non-resurrection rule: opting out of email must survive paying.
      u = member()

      {:ok, existing} =
        Newsletter.subscribe(%{email: to_string(u.email)}, authorize?: false, tenant: org_id())

      {:ok, _unsubscribed} =
        Newsletter.unsubscribe_subscriber(existing, authorize?: false, tenant: org_id())

      activate(u, tier())

      {:ok, reloaded} =
        Newsletter.get_subscriber(existing.id, authorize?: false, tenant: org_id())

      assert reloaded.status == :unsubscribed, "paying must not resurrect a withdrawn consent"
      assert reloaded.user_id == u.id, "...but the member link is still established"
    end

    test "cancelling removes the segment row but leaves consent alone" do
      u = member()
      t = tier()
      m = activate(u, t)

      {:ok, subscriber} =
        Newsletter.subscribers_for_user!(u.id, authorize?: false)
        |> List.first()
        |> Newsletter.resubscribe_subscriber(authorize?: false, tenant: org_id())

      assert subscriber.status == :confirmed

      {:ok, _canceled} =
        Billing.apply_provider_state(m, %{status: :canceled}, authorize?: false, tenant: org_id())

      segment = tier_segment(t)

      assert Newsletter.confirmed_subscribers!(segment.id, authorize?: false, tenant: org_id()) ==
               []

      {:ok, reloaded} =
        Newsletter.get_subscriber(subscriber.id, authorize?: false, tenant: org_id())

      assert reloaded.status == :confirmed, "cancelling a subscription is not withdrawing consent"
    end

    test "an unverified address is never added to a list" do
      # Sign-in doesn't require confirmation, so someone could register with a
      # stranger's address; that must not subscribe them to mail.
      u = member(%{confirmed_at: nil})

      activate(u, tier())

      assert Newsletter.subscribers_for_user!(u.id, authorize?: false) == []
    end

    test "syncing twice yields exactly one segment membership" do
      u = member()
      t = tier()
      m = activate(u, t)

      {:ok, _again} =
        Billing.apply_provider_state(m, %{status: :active}, authorize?: false, tenant: org_id())

      segment = tier_segment(t)

      rows =
        KilnCMS.Newsletter.SegmentMembership
        |> Ash.Query.for_read(:read, %{}, authorize?: false, tenant: org_id())
        |> Ash.Query.filter(segment_id == ^segment.id)
        |> Ash.read!()

      assert length(rows) == 1
    end
  end

  describe "the send guard" do
    test "a gated post CAN be sent to its tier-backed segment" do
      u = member()
      t = tier()
      activate(u, t)

      post = gated_post()
      segment = tier_segment(t)

      assert {:ok, _send} =
               Newsletter.send_as_newsletter(post, segment_id: segment.id, actor: admin())
    end

    test "a gated post is REFUSED to a hand-built segment carrying the same label" do
      # THE test. `Segment.audience` on a hand-built segment is a label and has
      # never been an access boundary; this feature must not turn it into one.
      post = gated_post()
      segment = hand_built_segment(%{audience: @gated})

      assert {:error, :gated} =
               Newsletter.send_as_newsletter(post, segment_id: segment.id, actor: admin())
    end

    test "a gated post is refused to a tier segment whose audience differs" do
      other = Enum.find(Audiences.gated(), &(&1 != @gated))

      if other do
        t = tier(%{audience: other})
        post = gated_post()
        segment = tier_segment(t)

        assert {:error, :gated} =
                 Newsletter.send_as_newsletter(post, segment_id: segment.id, actor: admin())
      end
    end

    test "a gated post is refused with NO segment — that's every subscriber" do
      post = gated_post()

      assert {:error, :gated} = Newsletter.send_as_newsletter(post, actor: admin())
    end

    test "a public post is still sendable to any segment" do
      post = public_post()
      segment = hand_built_segment()

      assert {:ok, _send} =
               Newsletter.send_as_newsletter(post, segment_id: segment.id, actor: admin())
    end

    test "a public post is still sendable with no segment" do
      assert {:ok, _send} = Newsletter.send_as_newsletter(public_post(), actor: admin())
    end

    test "an unpublished gated post reports :not_published, not :gated" do
      # Clause order: the state check must still win.
      t = tier()
      segment = tier_segment(t)

      {:ok, draft} =
        CMS.create_post(
          %{
            title: "Draft",
            slug: "draft-#{System.unique_integer([:positive])}",
            audience: @gated
          },
          actor: admin(),
          tenant: org_id()
        )

      assert {:error, :not_published} =
               Newsletter.send_as_newsletter(draft, segment_id: segment.id, actor: admin())
    end

    test "an unknown segment id is reported rather than silently ignored" do
      post = public_post()

      assert {:error, :no_such_segment} =
               Newsletter.send_as_newsletter(post,
                 segment_id: Ash.UUID.generate(),
                 actor: admin()
               )
    end
  end
end
