defmodule KilnCMS.Federation.AnnounceTest do
  @moduledoc """
  What federates, and what deliberately does not (#491).

  Every gate here is a decision about what gets broadcast to strangers'
  timelines, so the negative tests carry the weight: an audience-gated record
  reaching an outbox is a paywall leak, and a three-locale publish reaching one
  is three notifications for one article.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Federation.AnnounceWorker
  alias KilnCMS.Federation.Delivery
  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.SiteFederation

  @origin "https://kiln.example"
  @remote "https://remote.example/users/alice"

  setup do
    KilnCMS.FederationFixtures.enable_deployment!()
    org_id = KilnCMS.Accounts.default_org_id()

    Ash.create!(SiteFederation, %{origin: @origin, username: "kiln"},
      action: :enable,
      authorize?: false,
      tenant: org_id
    )

    Ash.create!(
      Follower,
      %{actor_uri: @remote, inbox_uri: @remote <> "/inbox"},
      action: :follow,
      authorize?: false,
      tenant: org_id
    )

    %{org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fed-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "fed-#{System.unique_integer([:positive])}"

  defp published_post(actor, attrs \\ %{}) do
    post =
      CMS.create_post!(
        Map.merge(
          %{
            title: "Federated",
            slug: slug(),
            blocks: [%{"_type" => "heading", "text" => "Hello"}]
          },
          attrs
        ),
        actor: actor
      )

    CMS.publish_post!(post, actor: actor)
  end

  defp announce(post, verb, org_id) do
    AnnounceWorker.perform(%Oban.Job{
      args: %{
        "org_id" => org_id,
        "type" => "post",
        "verb" => verb,
        "document_id" => post.id
      }
    })
  end

  defp deliveries(org_id), do: Ash.read!(Delivery, authorize?: false, tenant: org_id)

  describe "what federates" do
    test "a published public post becomes a Create per follower", %{actor: actor, org_id: org_id} do
      post = published_post(actor)

      assert :ok = announce(post, "Create", org_id)

      assert [delivery] = deliveries(org_id)
      assert delivery.activity_type == :create
      assert delivery.inbox_uri == @remote <> "/inbox"
      assert delivery.activity["type"] == "Create"
      assert delivery.activity["actor"] == "#{@origin}/actor"
      assert delivery.activity["object"]["type"] == "Article"
      assert delivery.activity["object"]["name"] == "Federated"

      # Addressed to the public collection, which is what makes it a public post
      # rather than a DM to every follower.
      assert "https://www.w3.org/ns/activitystreams#Public" in delivery.activity["to"]
    end

    test "an edit becomes an Update carrying the same object id", %{actor: actor, org_id: org_id} do
      post = published_post(actor)

      assert :ok = announce(post, "Create", org_id)
      assert :ok = announce(post, "Update", org_id)

      # Picked by activity type, not by position after sorting on
      # `inserted_at`. The two deliveries are written back-to-back and can land
      # on the same timestamp; `Enum.sort_by/2` is stable, so a tie falls back
      # to the order `deliveries/1` returned, and that is an unordered
      # `Ash.read!` — Postgres's incidental row order. Under full-suite load it
      # comes back reversed and this failed as `left: "Create"` (2026-08-12 on
      # #1237/#1238, again 2026-08-29 on #1343 — every one a PR touching no
      # federation code).
      #
      # Note an explicit `sort: [inserted_at: :asc]` would NOT fix it: the
      # collision is on `inserted_at` itself, so sorting by it has nothing to
      # break the tie with. Ordering was never the claim here anyway — that an
      # edit reuses the object id is.
      deliveries = deliveries(org_id)

      assert length(deliveries) == 2,
             "expected one Create and one Update delivery, got #{length(deliveries)}"

      create = Enum.find(deliveries, &(&1.activity["type"] == "Create"))
      update = Enum.find(deliveries, &(&1.activity["type"] == "Update"))

      assert create, "the initial announce did not record a Create delivery"

      assert update,
             "announcing an edit recorded no Update delivery — a second Create " <>
               "would mean the edit is federating as a new object"

      # The object id is what every remote server deduplicates on, so an edit
      # must reuse it rather than minting a new one.
      assert update.activity["object"]["id"] == create.activity["object"]["id"]
    end

    test "an unpublish becomes a Delete carrying a Tombstone, not the article",
         %{actor: actor, org_id: org_id} do
      post = published_post(actor)
      CMS.unpublish_post!(post, actor: actor)

      assert :ok = announce(post, "Delete", org_id)

      assert [delivery] = deliveries(org_id)
      assert delivery.activity["type"] == "Delete"
      assert delivery.activity["object"]["type"] == "Tombstone"
      # Re-sending the body in the activity that withdraws it would hand every
      # follower a copy of what was just taken down.
      refute delivery.activity["object"]["content"]
    end
  end

  describe "what does not federate" do
    test "a draft", %{actor: actor, org_id: org_id} do
      post = CMS.create_post!(%{title: "Draft", slug: slug()}, actor: actor)

      assert :ok = announce(post, "Create", org_id)
      assert [] = deliveries(org_id)
    end

    # An audience-gated record is published and paywalled, and an outbox is the
    # most public surface there is.
    test "an audience-gated post", %{actor: actor, org_id: org_id} do
      post = published_post(actor, %{audience: :member})

      assert :ok = announce(post, "Create", org_id)
      assert [] = deliveries(org_id)
    end

    test "a non-default-locale translation", %{actor: actor, org_id: org_id} do
      post = published_post(actor, %{locale: "fr"})

      assert :ok = announce(post, "Create", org_id)
      assert [] = deliveries(org_id)
    end

    test "a type the site does not syndicate", %{actor: actor, org_id: org_id} do
      post = published_post(actor)

      original = Application.get_env(:kiln_cms, :feeds, [])
      Application.put_env(:kiln_cms, :feeds, Keyword.put(original, :exclude, ["post"]))

      # The resolved policy is cached per org (#719), so the config layer under
      # it is only re-read after a bust — in production the operator config
      # can't change without a restart, but a test changes it mid-run.
      KilnCMS.Cache.bust_feed_policy(org_id)

      on_exit(fn ->
        Application.put_env(:kiln_cms, :feeds, original)
        KilnCMS.Cache.bust_feed_policy(org_id)
      end)

      assert :ok = announce(post, "Create", org_id)
      assert [] = deliveries(org_id)
    end

    test "anything, when the site has federation switched off", %{actor: actor, org_id: org_id} do
      post = published_post(actor)

      [settings] = Ash.read!(SiteFederation, authorize?: false, tenant: org_id)
      Ash.update!(settings, %{}, action: :disable, authorize?: false, tenant: org_id)

      assert :ok = announce(post, "Create", org_id)
      assert [] = deliveries(org_id)
    end

    test "a follower that has failed too often to still count", %{actor: actor, org_id: org_id} do
      [follower] = Ash.read!(Follower, authorize?: false, tenant: org_id)

      Enum.each(1..KilnCMS.Federation.drop_follower_after(), fn _ ->
        follower
        |> Ash.reload!(authorize?: false, tenant: org_id)
        |> Ash.update!(%{}, action: :record_failure, authorize?: false, tenant: org_id)
      end)

      post = published_post(actor)

      assert :ok = announce(post, "Create", org_id)
      assert [] = deliveries(org_id)
    end
  end

  describe "the event seam" do
    test "publishing enqueues an announcement through the webhook funnel",
         %{actor: actor, org_id: org_id} do
      post = CMS.create_post!(%{title: "Seam", slug: slug()}, actor: actor)
      CMS.publish_post!(post, actor: actor)

      assert_enqueued(
        worker: AnnounceWorker,
        args: %{"org_id" => org_id, "document_id" => post.id, "verb" => "Create"}
      )
    end

    # Workflow states are not publication events; a follower has no business
    # learning that a draft moved between editorial columns.
    test "an in-review transition enqueues nothing", %{actor: actor} do
      post = CMS.create_post!(%{title: "Review", slug: slug()}, actor: actor)
      CMS.submit_post_for_review!(post, actor: actor)

      refute_enqueued(worker: AnnounceWorker)
    end
  end
end
