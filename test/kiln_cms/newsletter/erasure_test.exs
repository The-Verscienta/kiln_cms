defmodule KilnCMS.Newsletter.ErasureTest do
  @moduledoc """
  Erasure deletes the newsletter subscriptions linked to the account (#2991).

  Before this, `AnonymizeUser` tombstoned the account and left its subscriber
  rows, so a confirmed subscription kept mailing the person's real address
  after they asked to be forgotten. Pinned here: the linked rows go on every
  site, with their segment memberships; rows that were never the account's
  stay; a delivery already queued cancels; the billing sync puts nothing
  back; the data-subject export lists the rows without their tokens; and
  `:for_user`, the member's cross-org lookup, is the member's alone.
  """
  # async: false — publishing a post fires its artifacts through Oban, drained
  # in the test process with the shared sandbox connection.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.MailWorker
  alias KilnCMS.Newsletter.SegmentMembership
  alias KilnCMS.Newsletter.Subscriber
  alias KilnCMS.Newsletter.TierSync

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: "nl-erase-#{role}-#{System.unique_integer([:positive])}@example.com",
      name: "Nl Erase",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp default_org, do: Accounts.default_org_id()

  # A confirmed subscriber row linked to `user` on `org_id`, the way billing
  # links one.
  defp linked(user, org_id) do
    opts = [authorize?: false, tenant: org_id]

    user.id
    |> Newsletter.link_member_subscriber!(%{email: to_string(user.email)}, opts)
    |> Newsletter.confirm_subscriber!(opts)
  end

  # A hand-added confirmed subscriber, never linked to an account.
  defp unlinked(email, org_id) do
    opts = [authorize?: false, tenant: org_id]

    %{email: email}
    |> Newsletter.subscribe!(opts)
    |> Newsletter.confirm_subscriber!(opts)
  end

  defp segment_with(subscriber) do
    opts = [authorize?: false, tenant: subscriber.org_id]

    segment =
      Newsletter.create_segment!(
        %{name: "Erasure #{System.unique_integer([:positive])}", slug: slug()},
        opts
      )

    Newsletter.add_to_segment!(%{segment_id: segment.id, subscriber_id: subscriber.id}, opts)
    segment
  end

  defp slug, do: "nl-erase-#{System.unique_integer([:positive])}"

  defp erase(user), do: Accounts.anonymize_user!(user, actor: user(:admin))

  defp subscriber_exists?(subscriber) do
    Newsletter.get_subscriber(subscriber.id,
      authorize?: false,
      tenant: subscriber.org_id,
      not_found_error?: false
    ) != {:ok, nil}
  end

  defp segment_rows(segment) do
    SegmentMembership
    |> Ash.Query.filter(segment_id == ^segment.id)
    |> then(
      &Newsletter.list_segment_memberships!(query: &1, authorize?: false, tenant: segment.org_id)
    )
  end

  describe "erasing an account" do
    test "deletes its linked subscriber rows on every site, with their segment memberships" do
      member = user()
      other = org("nl-erase-b").id

      here = linked(member, default_org())
      there = linked(member, other)
      segment = segment_with(here)
      assert [_row] = segment_rows(segment)

      erase(member)

      refute subscriber_exists?(here)
      refute subscriber_exists?(there)
      assert segment_rows(segment) == []
    end

    test "keeps a row never linked to it, on the same site and at the same address elsewhere" do
      member = user()
      address = to_string(member.email)
      third = org("nl-erase-c").id

      mine = linked(member, default_org())

      neighbour =
        unlinked(
          "nl-erase-other-#{System.unique_integer([:positive])}@example.com",
          default_org()
        )

      # Somebody added this address by hand on a site the account never
      # linked: it was not given through the account, so it is not erased with
      # it (a non-goal, pinned: matching on the address would reach a reused one).
      same_address = unlinked(address, third)

      erase(member)

      refute subscriber_exists?(mine)
      assert subscriber_exists?(neighbour)
      assert subscriber_exists?(same_address)
    end

    test "a delivery queued before the erasure cancels and mails nothing" do
      admin = user(:admin)
      member = user()
      address = to_string(member.email)
      subscriber = linked(member, default_org())

      post =
        CMS.create_post!(%{title: "Erasure #{slug()}", slug: slug()}, actor: admin)
        |> CMS.publish_post!(%{}, actor: admin)

      KilnCMS.DataCase.drain_oban()
      {:ok, send} = Newsletter.send_as_newsletter(post, actor: admin)

      erase(member)

      assert {:cancel, reason} =
               perform_job(MailWorker, %{
                 "newsletter_send_id" => send.id,
                 "subscriber_id" => subscriber.id,
                 "org_id" => send.org_id
               })

      assert reason =~ "not found"
      assert newsletters_to(address) == []
    end
  end

  describe "forget_member/1 fails closed" do
    # A refused read under the default `:filter` would match no rows, delete
    # nothing and answer `:ok`: an erasure reported done with the address
    # still on the list.
    test "a withdrawn grant raises instead of deleting nothing" do
      member = user()
      row = linked(member, default_org())

      for actor <- [nil, KilnCMS.SystemActor.new(:automation)] do
        capture_log(fn ->
          assert_raise RuntimeError, ~r/newsletter forget_member failed for org/, fn ->
            Newsletter.with_actor(actor, fn -> Newsletter.forget_member(member.id) end)
          end
        end)

        assert subscriber_exists?(row)
      end
    end

    test "a failure rolls the whole erasure back" do
      admin = user(:admin)
      member = user()
      row = linked(member, default_org())
      linked(member, org("nl-erase-rollback").id)

      {:ok, key} =
        Accounts.mint_api_key(member.id, "ci", DateTime.add(DateTime.utc_now(), 1, :day),
          authorize?: false
        )

      {result, log} =
        with_log(fn ->
          Newsletter.with_actor(nil, fn -> Accounts.anonymize_user(member, actor: admin) end)
        end)

      assert {:error, _error} = result

      reloaded = Accounts.get_user!(member.id, authorize?: false)
      assert reloaded.anonymized_at == nil
      assert to_string(reloaded.email) == to_string(member.email)
      assert subscriber_exists?(row)

      # Revoked earlier in the same after_action, so rolled back with it.
      assert [%{revoked_at: nil}] =
               Enum.filter(
                 Accounts.list_api_keys!(member.id, authorize?: false),
                 &(&1.id == key.id)
               )

      # Inside the erasure's transaction the first failure stops the sweep,
      # so the log names the org that failed and no other.
      assert length(Regex.scan(~r/newsletter forget_member failed for org/, log)) == 1
    end
  end

  describe "the billing sync after an erasure" do
    test "links no new row for an erased account, even with an entitlement left behind" do
      member = user()
      erased = erase(member)

      tier =
        Billing.create_tier!(
          %{
            name: "Erasure tier",
            slug: slug(),
            audience: hd(Audiences.gated()),
            provider_price_id: "price_#{System.unique_integer([:positive])}"
          },
          authorize?: false,
          tenant: default_org()
        )

      # A late webhook's view of the world: an active membership the erasure
      # never saw. The sync must not conjure a row for the tombstone.
      Ash.Seed.seed!(Billing.Membership, %{
        org_id: default_org(),
        user_id: erased.id,
        tier_id: tier.id,
        status: :active
      })

      assert :ok = TierSync.sync_user(erased.id, default_org())

      assert Subscriber
             |> Ash.Query.filter(user_id == ^erased.id)
             |> then(
               &Newsletter.list_subscribers!(query: &1, authorize?: false, tenant: default_org())
             )
             |> Enum.empty?()
    end
  end

  describe "export_user_data/1" do
    test "lists the account's linked subscriptions with their segments, and no tokens" do
      member = user()
      other = org("nl-erase-export").id
      here = linked(member, default_org())
      linked(member, other)
      segment = segment_with(here)

      # Not the account's: a stranger's row, and an unlinked one at this address.
      linked(user(), default_org())
      unlinked(to_string(member.email), org("nl-erase-export-c").id)

      export = Accounts.export_user_data(member)

      assert [_, _] = export.newsletter_subscriptions

      assert Enum.sort(Enum.map(export.newsletter_subscriptions, & &1.org_id)) ==
               Enum.sort([default_org(), other])

      entry = Enum.find(export.newsletter_subscriptions, &(&1.org_id == default_org()))
      assert entry.email == to_string(member.email)
      assert entry.status == :confirmed
      assert entry.segments == [segment.name]

      for entry <- export.newsletter_subscriptions do
        refute Map.has_key?(entry, :confirm_token)
        refute Map.has_key?(entry, :unsubscribe_token)
      end

      refute inspect(export) =~ here.unsubscribe_token
      refute inspect(export) =~ here.confirm_token
    end

    test "a refused read is logged as an error, not passed off as \"no subscriptions\"" do
      member = user()
      linked(member, default_org())

      {export, log} =
        with_log(fn ->
          Newsletter.with_actor(nil, fn -> Accounts.export_user_data(member) end)
        end)

      assert export.newsletter_subscriptions == []
      assert log =~ "data-subject export could not read newsletter subscriptions"
    end

    test "is empty for an erased account" do
      member = user()
      linked(member, default_org())

      assert Accounts.export_user_data(erase(member)).newsletter_subscriptions == []
    end
  end

  describe ":for_user is the member's own" do
    # `multitenancy :bypass`: the tenant does not narrow it, so an admin the
    # blanket policy admitted read the account's rows on every site, not only
    # the one they administer.
    test "a site admin cannot read a member's rows on any site through it" do
      site_a = org("nl-erase-site-a").id
      site_b = org("nl-erase-site-b").id
      site_admin = user(:viewer)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        organization_id: site_a,
        user_id: site_admin.id,
        role: :admin
      })

      member = user()
      linked(member, site_a)
      linked(member, site_b)

      assert {:ok, []} =
               Newsletter.subscribers_for_user(member.id, actor: site_admin, tenant: site_a)

      assert {:ok, []} = Newsletter.subscribers_for_user(member.id, actor: site_admin)
    end

    test "nor can a platform admin" do
      member = user()
      linked(member, default_org())

      assert {:ok, []} = Newsletter.subscribers_for_user(member.id, actor: user(:admin))
    end

    test "the member still reads their own, on every site" do
      member = user()
      linked(member, default_org())
      linked(member, org("nl-erase-own").id)

      assert {:ok, [_, _]} = Newsletter.subscribers_for_user(member.id, actor: member)
    end
  end

  defp newsletters_to(address) do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.filter(fn email ->
      Map.has_key?(email.headers, "List-Unsubscribe") and
        Enum.any?(email.to, fn {_name, to} -> to == address end)
    end)
  end
end
