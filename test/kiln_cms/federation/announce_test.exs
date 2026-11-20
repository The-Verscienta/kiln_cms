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
  alias KilnCMS.Federation
  alias KilnCMS.Federation.Announcer
  alias KilnCMS.Federation.AnnounceWorker
  alias KilnCMS.Federation.Delivery
  alias KilnCMS.Federation.DeliveryWorker
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

    # A release is not a document: its `release.published` shares a verb with
    # a publish, but no `release` type syndicates, so the worker would only
    # skip the job. The release's documents announce themselves.
    test "a domain event enqueues nothing", %{org_id: org_id} do
      for event <- ~w(release.published release.rolled_back form.submitted) do
        assert :ok = Announcer.announce(event, %{"id" => Ecto.UUID.generate()}, org_id)
      end

      refute_enqueued(worker: AnnounceWorker)

      # The same call with a document's event does enqueue.
      assert :ok = Announcer.announce("post.published", %{"id" => Ecto.UUID.generate()}, org_id)
      assert_enqueued(worker: AnnounceWorker, args: %{"verb" => "Create", "type" => "post"})
    end

    # Workflow states are not publication events; a follower has no business
    # learning that a draft moved between editorial columns.
    test "an in-review transition enqueues nothing", %{actor: actor} do
      post = CMS.create_post!(%{title: "Review", slug: slug()}, actor: actor)
      CMS.submit_post_for_review!(post, actor: actor)

      refute_enqueued(worker: AnnounceWorker)
    end
  end

  # #2753: a fan-out POSTs once per distinct inbox, not once per follower, and
  # writes its rows and jobs all-or-nothing so a retry does not re-send.
  describe "one delivery per inbox" do
    @shared "https://shared.example/inbox"
    @activity %{"type" => "Create", "id" => "https://kiln.example/ap/activity/create/1"}

    defp follow!(org_id, host, name, shared \\ nil) do
      uri = "https://#{host}/users/#{name}"

      Federation.follow!(uri, uri <> "/inbox", %{shared_inbox_uri: shared},
        authorize?: false,
        tenant: org_id
      )
    end

    defp row_at(org_id, inbox), do: Enum.filter(deliveries(org_id), &(&1.inbox_uri == inbox))

    defp delivery_jobs, do: all_enqueued(worker: DeliveryWorker)

    # The ledger rows and the jobs are one-to-one: every row has its job.
    defp assert_one_job_per_row(org_id) do
      row_ids = org_id |> deliveries() |> Enum.map(& &1.id) |> Enum.sort()
      job_ids = delivery_jobs() |> Enum.map(& &1.args["delivery_id"]) |> Enum.sort()
      assert job_ids == row_ids
    end

    test "followers sharing an inbox get one row and one job", %{actor: actor, org_id: org_id} do
      for name <- ~w(bob carol dave), do: follow!(org_id, "shared.example", name, @shared)

      assert :ok = announce(published_post(actor), "Create", org_id)

      # The shared inbox once, with no single follower named — and the setup's
      # personal-inbox follower beside it.
      assert [shared] = row_at(org_id, @shared)
      assert shared.follower_id == nil
      assert length(deliveries(org_id)) == 2
      assert length(delivery_jobs()) == 2
      assert_one_job_per_row(org_id)
    end

    test "followers on personal inboxes keep a row each, naming the follower",
         %{actor: actor, org_id: org_id} do
      bob = follow!(org_id, "other.example", "bob")
      [alice] = Federation.list_followers!(authorize?: false, tenant: org_id) |> without(bob)

      assert :ok = announce(published_post(actor), "Create", org_id)

      assert [%{follower_id: alice_id}] = row_at(org_id, @remote <> "/inbox")
      assert alice_id == alice.id
      assert [%{follower_id: bob_id}] = row_at(org_id, bob.inbox_uri)
      assert bob_id == bob.id
      assert_one_job_per_row(org_id)
    end

    test "shared and personal inboxes mixed: one row per distinct inbox",
         %{actor: actor, org_id: org_id} do
      for name <- ~w(bob carol dave), do: follow!(org_id, "shared.example", name, @shared)
      follow!(org_id, "other.example", "erin")

      assert :ok = announce(published_post(actor), "Create", org_id)

      assert deliveries(org_id) |> Enum.map(& &1.inbox_uri) |> Enum.sort() ==
               Enum.sort([@shared, @remote <> "/inbox", "https://other.example/users/erin/inbox"])

      assert length(delivery_jobs()) == 3
      assert_one_job_per_row(org_id)
    end

    test "an empty shared inbox is no shared inbox", %{actor: actor, org_id: org_id} do
      bob = follow!(org_id, "blank.example", "bob", "")
      carol = follow!(org_id, "blank.example", "carol", "")

      assert :ok = announce(published_post(actor), "Create", org_id)

      assert [%{follower_id: bob_id}] = row_at(org_id, bob.inbox_uri)
      assert bob_id == bob.id
      assert [%{follower_id: carol_id}] = row_at(org_id, carol.inbox_uri)
      assert carol_id == carol.id
      assert row_at(org_id, "") == []
    end

    # A group of one keeps the per-follower bookkeeping it always had, even
    # when its one follower delivers through a shared inbox.
    test "a shared inbox with one follower names that follower", %{actor: actor, org_id: org_id} do
      bob = follow!(org_id, "shared.example", "bob", @shared)

      assert :ok = announce(published_post(actor), "Create", org_id)

      assert [%{follower_id: bob_id}] = row_at(org_id, @shared)
      assert bob_id == bob.id
    end

    test "a blocked instance's shared inbox gets nothing", %{actor: actor, org_id: org_id} do
      for name <- ~w(bob carol), do: follow!(org_id, "shared.example", name, @shared)

      {:ok, _block} =
        Federation.block_and_drop(:instance, "shared.example", nil, actor: actor, tenant: org_id)

      assert :ok = announce(published_post(actor), "Create", org_id)

      assert row_at(org_id, @shared) == []
      assert [_alice] = deliveries(org_id)
    end

    # The failure lands on the LAST ledger batch, after earlier batches were
    # written: without the transaction those rows would survive, and the
    # worker's retry would queue their inboxes a second time.
    test "a failure part-way leaves nothing behind, and the retry queues each inbox once",
         %{actor: actor, org_id: org_id} do
      follow!(org_id, "aaa.example", "bob")
      broken = follow!(org_id, "zzz.example", "eve")

      # An inbox the ledger's own URL limit refuses — no action can write one,
      # so it is put there behind the actions' back.
      KilnCMS.Repo.query!(
        "UPDATE federation_followers SET inbox_uri = $1 WHERE id = $2",
        [
          "https://zzz.example/" <> String.duplicate("x", KilnCMS.Limits.url()),
          Ecto.UUID.dump!(broken.id)
        ]
      )

      post = published_post(actor)

      # The job fails, so Oban retries it, and it leaves nothing behind.
      assert {:error, _reason} = announce(post, "Create", org_id)
      assert deliveries(org_id) == []
      assert delivery_jobs() == []

      # One row per batch, so two batches are written before the third fails.
      assert {:error, %Ash.Error.Invalid{}} =
               Federation.deliver_to_followers(@activity, :create, post.id, org_id, batch_size: 1)

      assert deliveries(org_id) == []
      assert delivery_jobs() == []

      # Fixed, the retry queues each inbox exactly once.
      Federation.destroy_follower!(broken, authorize?: false, tenant: org_id)
      assert :ok = announce(post, "Create", org_id)

      assert deliveries(org_id) |> Enum.map(& &1.inbox_uri) |> Enum.sort() ==
               ["https://aaa.example/users/bob/inbox", @remote <> "/inbox"]

      assert length(delivery_jobs()) == 2
      assert_one_job_per_row(org_id)
    end

    # `Oban.insert_all` does not chunk, and one INSERT for a big site's fan-out
    # would pass Postgres's parameter limit.
    test "jobs are inserted in chunks, every one of them", %{org_id: org_id} do
      follow!(org_id, "aaa.example", "bob")
      follow!(org_id, "bbb.example", "carol")

      test_pid = self()
      handler = "fan-out-insert-all-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:oban, :engine, :insert_all_jobs, :stop],
        fn _event, _measurements, _meta, _config -> send(test_pid, :insert_all) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = Federation.deliver_to_followers(@activity, :create, nil, org_id, batch_size: 2)

      # Three inboxes in chunks of two: two inserts, three jobs.
      assert_received :insert_all
      assert_received :insert_all
      refute_received :insert_all

      assert length(delivery_jobs()) == 3
      assert_one_job_per_row(org_id)
    end

    test "no deliverable followers writes nothing", %{org_id: org_id} do
      org_id
      |> then(&Federation.list_followers!(authorize?: false, tenant: &1))
      |> Enum.each(&Federation.destroy_follower!(&1, authorize?: false, tenant: org_id))

      assert :ok = Federation.deliver_to_followers(@activity, :create, nil, org_id)
      assert deliveries(org_id) == []
      assert delivery_jobs() == []
    end
  end

  defp without(followers, %{id: id}), do: Enum.reject(followers, &(&1.id == id))
end
