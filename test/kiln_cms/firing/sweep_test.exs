defmodule KilnCMS.Firing.SweepTest do
  @moduledoc "Re-fire sweep (#357): refresh every published document's artifacts."
  # async: false — the announcement tests set the global `KilnCMS.CDN` and
  # `KilnCMS.Federation` app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import KilnCMS.TypedFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.Firing.{Engine, FireWorker, Sweep}

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sweep-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sweep-#{System.unique_integer([:positive])}"

  test "re-fires published documents and skips drafts" do
    actor = admin()
    org = KilnCMS.Accounts.default_org_id()

    published =
      CMS.create_page!(
        %{
          title: "Old",
          slug: slug(),
          blocks: typed_blocks([%{type: :heading, content: "H", order: 0}])
        },
        actor: actor
      )

    published = CMS.publish_page!(published, actor: actor)
    KilnCMS.DataCase.drain_oban()

    draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: actor)

    # Simulate pre-deploy content: purge its artifacts, as if fired by an old
    # release that lacked today's surfaces.
    :ok = Engine.purge(org, :page, published.id)
    assert :error = Engine.read(org, :page, published.id, :json_ld)

    counts = Sweep.run()
    assert counts.page >= 1
    KilnCMS.DataCase.drain_oban()

    # All four surfaces are back for the published page…
    {:ok, artifacts} = Firing.artifacts_for(:page, published.id, authorize?: false)
    assert artifacts |> Enum.map(& &1.surface) |> Enum.sort() == [:json, :json_ld, :llm, :web]

    # …and the draft never fired.
    {:ok, none} = Firing.artifacts_for(:page, draft.id, authorize?: false)
    assert none == []
  end

  test "sweeps the dynamic entry tier too" do
    actor = admin()
    org = KilnCMS.Accounts.default_org_id()

    definition =
      CMS.create_type_definition!(
        %{name: "swp#{System.unique_integer([:positive])}", label: "Sweepable"},
        actor: actor
      )

    entry =
      CMS.ContentTypes.create!(definition.name, %{title: "Swept", slug: slug()}, actor: actor)

    {:ok, entry} = CMS.ContentTypes.transition(definition.name, "publish", entry, actor: actor)
    KilnCMS.DataCase.drain_oban()

    :ok = Engine.purge(org, :entry, entry.id)

    counts = Sweep.run()
    assert counts.entry >= 1
    KilnCMS.DataCase.drain_oban()

    assert {:ok, _} = Engine.read(org, :entry, entry.id, :json_ld)
  end

  describe "announcing (#2463)" do
    setup do
      cdn = Application.get_env(:kiln_cms, KilnCMS.CDN, [])
      federation = Application.get_env(:kiln_cms, KilnCMS.Federation, [])

      on_exit(fn ->
        Application.put_env(:kiln_cms, KilnCMS.CDN, cdn)
        Application.put_env(:kiln_cms, KilnCMS.Federation, federation)
      end)

      Application.put_env(
        :kiln_cms,
        KilnCMS.CDN,
        Keyword.put(cdn, :purge_url, "https://purge.example.test/purge")
      )

      Application.put_env(:kiln_cms, KilnCMS.Federation, Keyword.put(federation, :enabled, true))

      actor = admin()
      org = KilnCMS.Accounts.default_org_id()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)

      # An "any type, on updated" rule: what a notifying sweep must not run.
      KilnCMS.Automation.create_rule!(
        %{name: "Any type, on updated", trigger_event: :updated, action: :broadcast, config: %{}},
        actor: actor,
        tenant: org
      )

      # Seeded straight into the published state, so no publish of its own
      # dispatches or enqueues anything.
      page =
        Ash.Seed.seed!(CMS.Page, %{
          title: "Swept",
          slug: slug(),
          state: :published,
          blocks: [%{"_type" => "heading", "text" => "H"}]
        })

      %{org: org, page: page}
    end

    defp deliveries(org), do: CMS.list_webhook_deliveries!(authorize?: false, tenant: org)

    test "a default sweep re-fires silently", %{org: org, page: page} do
      Sweep.run()

      for job <- all_enqueued(worker: FireWorker) do
        refute Map.has_key?(job.args, "refire")
        refute Map.has_key?(job.args, "announce")
      end

      Oban.drain_queue(queue: :firing, with_recursion: true)

      assert {:ok, _} = Engine.read(org, :page, page.id, :json)
      assert deliveries(org) == []
      refute_enqueued(worker: KilnCMS.CDN.PurgeWorker)
      refute_enqueued(worker: KilnCMS.Automation.DispatchWorker)
    end

    test "notify: true tells the webhook endpoints and the change feed, and nobody else",
         %{org: org, page: page} do
      :ok = KilnCMS.Delivery.Feed.subscribe(org)

      Sweep.run(notify: true)

      assert [%{args: args}] = all_enqueued(worker: FireWorker)
      assert %{"announce" => "delivery", "id" => id} = args
      # Not a refire: `Firing.refire/3` dedupes on that flag (see below).
      refute Map.has_key?(args, "refire")
      assert id == page.id

      Oban.drain_queue(queue: :firing, with_recursion: true)

      assert {:ok, _} = Engine.read(org, :page, page.id, :json)

      # The endpoint hears `updated`, marked as a re-render rather than an edit.
      assert [delivery] = deliveries(org)
      assert delivery.event == "page.updated"
      assert delivery.payload["reason"] == "refire"
      assert delivery.payload["id"] == page.id
      assert_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)

      # The change feed hears it too.
      page_id = page.id
      KilnCMS.Delivery.Feed.sync(org)
      assert_received {:kiln_feed, %KilnCMS.Delivery.Feed.Event{kind: :updated, id: ^page_id}}

      # Not a purge per document, not automation, not federation.
      refute_enqueued(worker: KilnCMS.CDN.PurgeWorker)
      refute_enqueued(worker: KilnCMS.Automation.DispatchWorker)
      refute_enqueued(worker: KilnCMS.Federation.AnnounceWorker)
    end

    test "a refire asked for while a notifying sweep job is pending gets its own full announcement",
         %{org: org, page: page} do
      Sweep.run(notify: true)

      assert KilnCMS.Firing.refire!("page", [page.id],
               actor: KilnCMS.SystemActor.new(:overlay),
               tenant: org
             ) == 1

      assert [_sweep, _refire] = all_enqueued(worker: FireWorker)

      Oban.drain_queue(queue: :firing, with_recursion: true)

      # One `updated` per job, both marked as re-renders…
      deliveries = deliveries(org)
      assert length(deliveries) == 2
      assert Enum.all?(deliveries, &(&1.event == "page.updated"))
      assert Enum.all?(deliveries, &(&1.payload["reason"] == "refire"))

      # …and the refire's reached the consumers the sweep's skips.
      assert_enqueued(worker: KilnCMS.CDN.PurgeWorker, args: %{"org_id" => org})
      assert_enqueued(worker: KilnCMS.Automation.DispatchWorker)
      assert_enqueued(worker: KilnCMS.Federation.AnnounceWorker)
    end

    test "a one-type sweep stays silent", %{org: org, page: page} do
      assert Sweep.sweep_type(org, "page") >= 1

      for job <- all_enqueued(worker: FireWorker) do
        refute Map.has_key?(job.args, "refire")
        refute Map.has_key?(job.args, "announce")
      end

      Oban.drain_queue(queue: :firing, with_recursion: true)

      assert {:ok, _} = Engine.read(org, :page, page.id, :json)
      assert deliveries(org) == []
      refute_enqueued(worker: KilnCMS.CDN.PurgeWorker)
    end
  end
end
