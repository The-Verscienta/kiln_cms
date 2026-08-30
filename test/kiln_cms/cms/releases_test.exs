defmodule KilnCMS.CMS.ReleasesTest do
  @moduledoc """
  Content releases (#500): the model's conflict rule, the authorization split
  between composing and shipping a release, and — the point of the whole feature
  — that go-live is genuinely all-or-nothing.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Releases

  defp user(role, extra \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "release-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  # Created through the real `:create` action, not seeded: a seeded row has no
  # create version, so folding its history back reconstructs nils — the version
  # machinery these tests lean on only behaves like production if the content
  # was authored like production content.
  defp n, do: System.unique_integer([:positive])

  defp page(attrs \\ %{}) do
    n = n()

    {:ok, page} =
      CMS.create_page(%{title: "Release page #{n}", slug: "release-page-#{n}"},
        authorize?: false
      )

    case Map.get(attrs, :state) do
      nil -> page
      state -> Ash.Seed.update!(page, %{state: state})
    end
  end

  defp release(admin, attrs \\ %{}) do
    {:ok, release} =
      CMS.create_release(Map.merge(%{name: "Spring campaign"}, attrs), actor: admin)

    release
  end

  defp add(release, record, admin, action \\ :publish) do
    CMS.add_release_item(
      %{release_id: release.id, content_type: "page", content_id: record.id, action: action},
      actor: admin
    )
  end

  defp reload(release), do: CMS.get_release!(release.id, authorize?: false)
  defp reload_page(page), do: CMS.get_page!(page.id, authorize?: false)

  # Claim + run in one step, the way the console's "Publish now" and the cron
  # both do (claim, then the worker). Drains Oban so the enqueued worker runs.
  defp go_live(release, admin) do
    {:ok, claimed} = CMS.start_release(release, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    {:ok, reload(claimed)}
  end

  describe "composing a release" do
    test "a record may appear in at most one open release" do
      admin = user(:admin)
      one = release(admin, %{name: "One"})
      two = release(admin, %{name: "Two"})
      p = page()

      assert {:ok, _item} = add(one, p, admin)
      assert {:error, %Ash.Error.Invalid{}} = add(two, p, admin)
    end

    test "cancelling an item frees the record for another release" do
      admin = user(:admin)
      one = release(admin, %{name: "One"})
      two = release(admin, %{name: "Two"})
      p = page()

      {:ok, item} = add(one, p, admin)
      {:ok, _} = CMS.cancel_release_item(item, %{}, actor: admin)

      assert {:ok, _} = add(two, p, admin)
    end

    test "archiving an unshipped release frees its items" do
      admin = user(:admin)
      one = release(admin, %{name: "One"})
      two = release(admin, %{name: "Two"})
      p = page()

      {:ok, _item} = add(one, p, admin)
      {:ok, _} = CMS.archive_release(one, %{}, actor: admin)

      assert {:ok, _} = add(two, p, admin)
    end

    test "a shipped release refuses new items" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      assert {:error, %Ash.Error.Invalid{}} = add(published, page(), admin)
    end

    test "a release that shipped cannot be deleted, only archived" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, published} = go_live(rel, admin)

      assert {:error, %Ash.Error.Invalid{}} = CMS.destroy_release(published, actor: admin)
      assert {:ok, _} = CMS.archive_release(published, %{}, actor: admin)
    end

    test "an unshipped release can be deleted and takes its items with it" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, item} = add(rel, page(), admin)

      assert :ok = CMS.destroy_release(rel, actor: admin)
      assert {:error, _} = CMS.get_release_item(item.id, authorize?: false)
    end

    test "a content_id that resolves to nothing is refused at add time, not go-live" do
      # Without this, a stale/bogus id sits :pending until go-live, where
      # `Releases.apply_all/4` rolls back the WHOLE release on the first
      # `fetch_record` miss — taking every other admin-approved item down with
      # it. Refusing here is the whole fix.
      admin = user(:admin)
      rel = release(admin)
      good = page()

      assert {:ok, _} = add(rel, good, admin)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.add_release_item(
                 %{
                   release_id: rel.id,
                   content_type: "page",
                   content_id: Ash.UUID.generate(),
                   action: :publish
                 },
                 actor: admin
               )

      assert Exception.message(error) =~ "does not resolve to an existing record"

      # The good item's slot must not have been consumed by the failed add.
      assert [_] = CMS.list_release_items_with_status!(rel.id, :pending, authorize?: false)
    end
  end

  describe "size cap" do
    setup do
      previous = Application.get_env(:kiln_cms, Releases, [])
      Application.put_env(:kiln_cms, Releases, Keyword.put(previous, :max_items, 2))
      on_exit(fn -> Application.put_env(:kiln_cms, Releases, previous) end)
      :ok
    end

    test "a full release refuses further items" do
      admin = user(:admin)
      rel = release(admin)

      assert {:ok, _} = add(rel, page(), admin)
      assert {:ok, _} = add(rel, page(), admin)

      assert {:error, %Ash.Error.Invalid{} = error} = add(rel, page(), admin)
      assert Exception.message(error) =~ "full"

      assert 2 =
               rel.id
               |> CMS.list_release_items_with_status!(:pending, authorize?: false)
               |> length()
    end

    test "removing an item frees a slot" do
      admin = user(:admin)
      rel = release(admin)

      {:ok, item} = add(rel, page(), admin)
      {:ok, _} = add(rel, page(), admin)
      assert {:error, %Ash.Error.Invalid{}} = add(rel, page(), admin)

      {:ok, _} = CMS.cancel_release_item(item, %{}, actor: admin)
      assert {:ok, _} = add(rel, page(), admin)
    end

    test "the cap counts only pending items, so a shipped release doesn't block a new one" do
      admin = user(:admin)
      shipped = release(admin, %{name: "Shipped"})
      {:ok, _} = add(shipped, page(), admin)
      {:ok, _} = add(shipped, page(), admin)
      {:ok, published} = go_live(shipped, admin)
      assert published.state == :published

      # Its items are :applied now, not :pending — a fresh release starts empty.
      fresh = release(admin, %{name: "Fresh"})
      assert {:ok, _} = add(fresh, page(), admin)
      assert {:ok, _} = add(fresh, page(), admin)
    end

    test "the cap and the transaction timeout are configurable" do
      assert Releases.max_items() == 2

      Application.put_env(:kiln_cms, Releases, max_items: 7, transaction_timeout_ms: 1_000)
      assert Releases.max_items() == 7
      assert Releases.transaction_timeout_ms() == 1_000
    end
  end

  describe "authorization" do
    test "editors compose releases but may not ship them" do
      editor = user(:editor)
      rel = release(editor, %{name: "Editor's plan"})
      assert rel.creator_id == editor.id

      assert {:ok, _} = add(rel, page(), editor)

      # Publishing content is an admin approval step; a release must not be a
      # way around it.
      assert {:error, %Ash.Error.Forbidden{}} = CMS.start_release(rel, %{}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.schedule_release(rel, %{scheduled_at: DateTime.utc_now()}, actor: editor)
    end

    test "a type-scoped editor cannot smuggle out-of-scope content into a release" do
      # Granular RBAC (#332). The preview link renders every pending item's full
      # unpublished body to whoever holds it, so "add to release" has to enforce
      # the same type scope every other content write does — otherwise it is a
      # read of content this editor is explicitly denied.
      admin = user(:admin)
      scoped = user(:editor, %{editable_types: ["post"], readable_types: ["post"]})
      rel = release(admin)
      page = page()

      assert {:error, %Ash.Error.Invalid{}} = add(rel, page, scoped)
      assert [] = CMS.list_release_items_for!(rel.id, authorize?: false)

      # ...and the same editor CAN add a type they hold.
      {:ok, post} =
        CMS.create_post(%{title: "In scope", slug: "in-scope-#{n()}"}, authorize?: false)

      assert {:ok, _} =
               CMS.add_release_item(
                 %{release_id: rel.id, content_type: "post", content_id: post.id},
                 actor: scoped
               )
    end

    test "a release cannot be created already scheduled" do
      # `:schedule` is admin-only precisely so an editor can't arrange for the
      # cron to publish on their behalf. Accepting `scheduled_at` on `:create`
      # would have handed that straight back.
      editor = user(:editor)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_release(%{name: "Sneaky", scheduled_at: DateTime.utc_now()},
                 actor: editor
               )

      {:ok, rel} = CMS.create_release(%{name: "Honest"}, actor: editor)
      assert rel.state == :open
      assert is_nil(rel.scheduled_at)
    end

    test "an editor may not archive or delete a release an admin committed" do
      admin = user(:admin)
      editor = user(:editor)

      scheduled = release(admin, %{name: "Scheduled"})
      {:ok, _} = add(scheduled, page(), admin)

      {:ok, scheduled} =
        CMS.schedule_release(scheduled, %{scheduled_at: DateTime.utc_now()}, actor: admin)

      # Archiving would cancel the launch; deleting would remove it outright.
      assert {:error, %Ash.Error.Forbidden{}} = CMS.archive_release(scheduled, %{}, actor: editor)
      assert {:error, %Ash.Error.Forbidden{}} = CMS.destroy_release(scheduled, actor: editor)

      shipped = release(admin, %{name: "Shipped"})
      {:ok, _} = add(shipped, page(), admin)
      {:ok, shipped} = go_live(shipped, admin)

      # Archiving is one-way, so this would permanently destroy the rollback.
      assert {:error, %Ash.Error.Forbidden{}} = CMS.archive_release(shipped, %{}, actor: editor)
      assert {:ok, _} = CMS.archive_release(shipped, %{}, actor: admin)
    end

    test "the system mark_* writes are unreachable even for an admin" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      # Claim it, so the state machine would ALLOW the transition and the policy
      # is what actually refuses.
      {:ok, claimed} = CMS.start_release(rel, %{}, actor: admin)

      # No blanket admin bypass: a human stamping a release `:published` that
      # never published would make the console lie about the site, and
      # `mark_applied` would let one rewrite what rollback restores.
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.mark_release_published(claimed, %{}, actor: admin)

      KilnCMS.DataCase.drain_oban()
    end

    test "viewers see nothing and can compose nothing" do
      admin = user(:admin)
      viewer = user(:viewer)
      _rel = release(admin)

      # Read policies filter rather than raise, so a viewer sees an empty list —
      # never another site's or role's release names.
      assert {:ok, []} = CMS.list_releases(actor: viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_release(%{name: "Sneaky"}, actor: viewer)
    end
  end

  describe "atomic go-live" do
    test "every item publishes and the release records who shipped it" do
      admin = user(:admin)
      rel = release(admin)
      a = page()
      b = page()
      {:ok, _} = add(rel, a, admin)
      {:ok, _} = add(rel, b, admin)

      {:ok, published} = go_live(rel, admin)

      assert published.state == :published
      assert published.published_at
      assert published.triggered_by_id == admin.id
      assert reload_page(a).state == :published
      assert reload_page(b).state == :published

      assert [_, _] = CMS.list_release_items_with_status!(rel.id, :applied, authorize?: false)
    end

    test "one bad item leaves NOTHING live and names the item that broke" do
      admin = user(:admin)
      rel = release(admin)
      good = page()
      # Archived content cannot transition to published — a real, unfixable-by-
      # retry failure.
      bad = page(%{state: :archived})

      {:ok, _} = add(rel, good, admin)
      {:ok, bad_item} = add(rel, bad, admin)

      {:ok, failed} = go_live(rel, admin)

      assert failed.state == :failed
      assert failed.failed_item_id == bad_item.id
      assert failed.failure_reason =~ "archived"

      # The whole point: the good item did NOT go live.
      assert reload_page(good).state == :draft
      assert reload_page(bad).state == :archived

      # And every item is still pending, so a retry after the fix re-runs them.
      assert [_, _] = CMS.list_release_items_with_status!(rel.id, :pending, authorize?: false)
    end

    test "a failed go-live rolls back the webhook deliveries it queued" do
      admin = user(:admin)

      {:ok, _endpoint} =
        CMS.create_webhook_endpoint(
          %{url: "https://example.com/hook", events: ["page.published"], active: true},
          actor: admin
        )

      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, _} = add(rel, page(%{state: :archived}), admin)

      {:ok, failed} = go_live(rel, admin)
      assert failed.state == :failed

      # Nothing published, so nothing may have been recorded for delivery — the
      # ledger row and its Oban job are DB writes inside the same transaction.
      assert [] = CMS.recent_webhook_deliveries!(authorize?: false)
    end

    test "an item whose change is already true is skipped, not failed" do
      admin = user(:admin)
      rel = release(admin)
      already = page()
      other = page()

      {:ok, skipped_item} = add(rel, already, admin)
      {:ok, _} = add(rel, other, admin)

      # Somebody publishes it by hand before the release fires.
      {:ok, _} = CMS.publish_page(already, %{}, actor: admin)

      {:ok, published} = go_live(rel, admin)

      assert published.state == :published
      assert CMS.get_release_item!(skipped_item.id, authorize?: false).status == :skipped
      assert reload_page(other).state == :published
    end

    test "readiness reports what would happen without changing anything" do
      admin = user(:admin)
      rel = release(admin)
      ok_page = page()
      bad_page = page(%{state: :archived})
      {:ok, _} = add(rel, ok_page, admin)
      {:ok, _} = add(rel, bad_page, admin)

      results = rel |> Releases.readiness() |> Enum.map(fn {item, class} -> {item.id, class} end)

      assert Enum.any?(results, fn {_id, class} -> class == :apply end)
      assert Enum.any?(results, fn {_id, class} -> match?({:error, _}, class) end)
      assert reload_page(ok_page).state == :draft
    end

    test "a scheduled release goes live on the minute cron" do
      admin = user(:admin)
      rel = release(admin)
      p = page()
      {:ok, _} = add(rel, p, admin)

      {:ok, scheduled} =
        CMS.schedule_release(rel, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60)},
          actor: admin
        )

      assert scheduled.state == :scheduled

      AshOban.schedule_and_run_triggers(KilnCMS.CMS.ContentRelease)
      KilnCMS.DataCase.drain_oban()

      assert reload(rel).state == :published
      assert reload_page(p).state == :published
    end
  end

  describe "claiming a release" do
    test "a second claim from a stale struct is refused, not duplicated" do
      # The console page an admin has had open since 08:59 still says
      # `:scheduled` after the 09:00 cron claimed the release. Without a
      # compare-and-swap on the UPDATE itself, "Publish now" at 09:00:05 would
      # validate against that stale struct and ship the bundle a second time.
      admin = user(:admin)

      {:ok, _endpoint} =
        CMS.create_webhook_endpoint(
          %{
            url: "https://example.com/once",
            events: ["release.published"],
            active: true
          },
          actor: admin
        )

      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)

      assert {:ok, _claimed} = CMS.start_release(rel, %{}, actor: admin)
      assert {:error, _stale} = CMS.start_release(rel, %{}, actor: admin)

      KilnCMS.DataCase.drain_oban()

      assert reload(rel).state == :published
      # One go-live, so exactly one release.published, not two.
      assert 1 =
               CMS.recent_webhook_deliveries!(authorize?: false)
               |> Enum.count(&(&1.event == "release.published"))
    end

    test "publishing an already-published release is a no-op, not a second run" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, published} = go_live(rel, admin)

      assert {:error, {:unexpected_state, :published}} = Releases.publish(published)
      assert reload(rel).published_at == published.published_at
    end

    test "a stuck claim can be released and the release retried" do
      # `:publishing` means "a worker owns this". A worker that died leaves
      # nobody to say otherwise: without `:abandon` the release is wedged
      # forever AND its items keep reserving their content against every other
      # release, with no UI able to free them.
      admin = user(:admin)
      rel = release(admin)
      p = page()
      {:ok, _} = add(rel, p, admin)

      {:ok, claimed} = CMS.start_release(rel, %{}, actor: admin)
      assert claimed.state == :publishing

      # Nothing else moves a release out of :publishing.
      assert {:error, _} = CMS.archive_release(claimed, %{}, actor: admin)
      assert {:error, _} = CMS.reopen_release(claimed, %{}, actor: admin)
      assert {:error, _} = CMS.destroy_release(claimed, actor: admin)

      {:ok, abandoned} = CMS.abandon_release(claimed, %{}, actor: admin)
      assert abandoned.state == :failed
      assert abandoned.failure_reason =~ "Abandoned"

      # And the retry path works end to end.
      {:ok, reopened} = CMS.reopen_release(abandoned, %{}, actor: admin)
      {:ok, published} = go_live(reopened, admin)
      assert published.state == :published
      assert reload_page(p).state == :published
    end

    test "abandoning a rollback returns the release to published" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, published} = go_live(rel, admin)

      {:ok, claimed} = CMS.start_release_rollback(published, %{}, actor: admin)
      assert claimed.state == :rolling_back

      {:ok, abandoned} = CMS.abandon_release(claimed, %{}, actor: admin)
      # The site is still live, so `:published` is what remains true of it.
      assert abandoned.state == :published

      KilnCMS.DataCase.drain_oban()
    end

    test "only admins may release a stuck claim" do
      admin = user(:admin)
      editor = user(:editor)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, claimed} = CMS.start_release(rel, %{}, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} = CMS.abandon_release(claimed, %{}, actor: editor)
      KilnCMS.DataCase.drain_oban()
    end
  end

  describe "release.published event" do
    test "is selectable as a webhook subscription and dispatched on go-live" do
      admin = user(:admin)

      assert "release.published" in CMS.WebhookEndpoint.events()
      assert "release.rolled_back" in CMS.WebhookEndpoint.events()

      {:ok, endpoint} =
        CMS.create_webhook_endpoint(
          %{
            url: "https://example.com/release-hook",
            events: ["release.published"],
            active: true
          },
          actor: admin
        )

      rel = release(admin)
      p = page()
      {:ok, _} = add(rel, p, admin)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      deliveries = CMS.recent_webhook_deliveries!(authorize?: false)
      release_delivery = Enum.find(deliveries, &(&1.event == "release.published"))

      assert release_delivery
      assert release_delivery.endpoint_id == endpoint.id
      assert release_delivery.payload["name"] == rel.name
      assert [%{"type" => "page", "action" => "publish"}] = release_delivery.payload["items"]
    end
  end

  describe "group rollback" do
    test "restores each item's prior workflow state" do
      admin = user(:admin)
      rel = release(admin)
      fresh = page()
      reviewed = page(%{state: :in_review})

      {:ok, _} = add(rel, fresh, admin)
      {:ok, _} = add(rel, reviewed, admin)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert reload(rel).state == :rolled_back
      assert reload_page(fresh).state == :draft
      # An unpublish always lands in :draft; rollback puts the review back.
      assert reload_page(reviewed).state == :in_review
    end

    test "an unpublish item is restored to the exact body that was live" do
      admin = user(:admin)
      live = page()
      {:ok, live} = CMS.publish_page(live, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      rel = release(admin)
      {:ok, _} = add(rel, live, admin, :unpublish)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published
      assert reload_page(live).state == :draft

      # The content drifts while it is dark.
      {:ok, _} = CMS.update_page(reload_page(live), %{title: "Drifted while dark"}, actor: admin)

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      restored = reload_page(live)
      assert reload(rel).state == :rolled_back
      assert restored.state == :published
      refute restored.title == "Drifted while dark"
    end

    test "skipped items are left alone by a rollback" do
      admin = user(:admin)
      already = page()
      {:ok, _} = CMS.publish_page(already, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      rel = release(admin)
      {:ok, _} = add(rel, already, admin)
      {:ok, published} = go_live(rel, admin)

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      # The release didn't put it live, so rollback must not take it down.
      assert reload_page(already).state == :published
    end

    test "a deleted item doesn't strand the rest of the group live" do
      # Without an escape for content that is simply gone, one purged page makes
      # rollback fail identically on every retry — leaving every OTHER item of
      # the release live with no way to take the group down.
      admin = user(:admin)
      rel = release(admin)
      survivor = page()
      doomed = page()
      {:ok, _} = add(rel, survivor, admin)
      {:ok, _} = add(rel, doomed, admin)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      :ok = CMS.purge_page(reload_page(doomed), authorize?: false)

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert reload(rel).state == :rolled_back
      assert reload_page(survivor).state == :draft
    end

    test "an untouched record is republished without cutting a restore version" do
      admin = user(:admin)
      live = page()
      {:ok, live} = CMS.publish_page(live, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      rel = release(admin)
      {:ok, _} = add(rel, live, admin, :unpublish)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      before = CMS.list_page_versions!(authorize?: false) |> Enum.count()

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert reload_page(live).state == :published

      # The republish cuts one version. A needless restore would cut two —
      # and, for content whose history predates version tracking, could fail
      # outright and abort a rollback with nothing to reconstruct.
      assert CMS.list_page_versions!(authorize?: false) |> Enum.count() == before + 1
    end

    test "a rollback that cannot complete leaves the release published" do
      admin = user(:admin)

      img =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "r-#{n()}.png",
          url: "/uploads/r-#{n()}.png",
          content_type: "image/png"
        })

      # Live, with an image that has no alt text.
      {:ok, live} =
        CMS.create_page(
          %{
            title: "Alt-less",
            slug: "alt-less-#{n()}",
            blocks: [%{"_type" => "image", "url" => img.url, "media_id" => img.id, "alt" => nil}]
          },
          authorize?: false
        )

      {:ok, live} = CMS.publish_page(live, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      rel = release(admin)
      {:ok, _} = add(rel, live, admin, :unpublish)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      # Rolling back has to REPUBLISH it — and now the accessibility gate is on,
      # so that publish is refused. This also exercises the Ash-rollback branch
      # of `describe_failure/2`: the failure comes from inside an Ash action, not
      # from our own classification.
      Application.put_env(:kiln_cms, :media, require_alt_text: true)
      on_exit(fn -> Application.put_env(:kiln_cms, :media, []) end)

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      after_attempt = reload(rel)
      assert after_attempt.state == :published
      assert after_attempt.failure_reason =~ "alt"
      # Nothing moved, so a retry after fixing the image still works.
      assert reload_page(live).state == :draft
      assert [_] = CMS.list_release_items_with_status!(rel.id, :applied, authorize?: false)
    end

    test "a failed rollback dispatches release.failed with mode rollback" do
      admin = user(:admin)

      {:ok, _endpoint} =
        CMS.create_webhook_endpoint(
          %{
            url: "https://example.com/rollback-fail-hook",
            events: ["release.failed"],
            active: true
          },
          actor: admin
        )

      img =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "rf-#{n()}.png",
          url: "/uploads/rf-#{n()}.png",
          content_type: "image/png"
        })

      {:ok, live} =
        CMS.create_page(
          %{
            title: "Alt-less rollback",
            slug: "alt-less-rb-#{n()}",
            blocks: [%{"_type" => "image", "url" => img.url, "media_id" => img.id, "alt" => nil}]
          },
          authorize?: false
        )

      {:ok, live} = CMS.publish_page(live, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      rel = release(admin)
      {:ok, _} = add(rel, live, admin, :unpublish)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      Application.put_env(:kiln_cms, :media, require_alt_text: true)
      on_exit(fn -> Application.put_env(:kiln_cms, :media, []) end)

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert reload(rel).state == :published

      delivery =
        CMS.recent_webhook_deliveries!(authorize?: false)
        |> Enum.find(&(&1.event == "release.failed"))

      assert delivery, "a rollback that aborts is as silent as a go-live that does"
      assert delivery.payload["mode"] == "rollback"
      assert delivery.payload["failure_reason"] =~ "alt"
      # It stays PUBLISHED — that is still what is true of the site.
      assert delivery.payload["state"] == "published"
    end

    test "only admins may roll a release back" do
      admin = user(:admin)
      editor = user(:editor)
      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, published} = go_live(rel, admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.start_release_rollback(published, %{}, actor: editor)
    end
  end

  describe "release.failed event" do
    test "a go-live that aborts is not silent" do
      admin = user(:admin)

      assert "release.failed" in CMS.WebhookEndpoint.events()

      {:ok, endpoint} =
        CMS.create_webhook_endpoint(
          %{
            url: "https://example.com/release-failure-hook",
            events: ["release.failed"],
            active: true
          },
          actor: admin
        )

      rel = release(admin)
      good = page()
      bad = page(%{state: :archived})
      {:ok, _} = add(rel, good, admin)
      {:ok, bad_item} = add(rel, bad, admin)

      {:ok, failed} = go_live(rel, admin)
      assert failed.state == :failed

      delivery =
        CMS.recent_webhook_deliveries!(authorize?: false)
        |> Enum.find(&(&1.event == "release.failed"))

      assert delivery, "an unattended release that aborts must tell somebody"
      assert delivery.endpoint_id == endpoint.id
      assert delivery.payload["mode"] == "publish"
      assert delivery.payload["name"] == rel.name
      assert delivery.payload["failed_item_id"] == bad_item.id
      assert delivery.payload["failure_reason"] =~ "archived"
    end

    test "the abort's own dispatch survives the go-live rollback" do
      admin = user(:admin)

      {:ok, _endpoint} =
        CMS.create_webhook_endpoint(
          %{
            url: "https://example.com/release-failure-survives",
            events: ["release.published", "release.failed"],
            active: true
          },
          actor: admin
        )

      rel = release(admin)
      {:ok, _} = add(rel, page(), admin)
      {:ok, _} = add(rel, page(%{state: :archived}), admin)
      {:ok, failed} = go_live(rel, admin)
      assert failed.state == :failed

      events = CMS.recent_webhook_deliveries!(authorize?: false) |> Enum.map(& &1.event)

      # The success event was queued INSIDE the transaction and died with it;
      # the failure event is dispatched after it and must not have.
      refute "release.published" in events
      assert "release.failed" in events
    end
  end

  describe "the go-live time budget" do
    setup do
      previous = Application.get_env(:kiln_cms, Releases, [])
      on_exit(fn -> Application.put_env(:kiln_cms, Releases, previous) end)
      %{previous: previous}
    end

    test "deadline_left counts down from the configured budget", %{previous: previous} do
      Application.put_env(:kiln_cms, Releases, Keyword.put(previous, :transaction_timeout_ms, 50))

      deadline = Releases.deadline()
      assert Releases.deadline_left(deadline) <= 50
      Process.sleep(60)
      assert Releases.deadline_left(deadline) <= 0
    end

    test "an exhausted budget aborts the release and publishes NOTHING", %{previous: previous} do
      admin = user(:admin)
      rel = release(admin)
      a = page()
      b = page()
      {:ok, one} = add(rel, a, admin)
      {:ok, two} = add(rel, b, admin)

      # A 1ms budget is spent while the first item is being applied, so the
      # check before the second one trips — the same code path a 500-item
      # release exceeding two minutes takes. Which item it stops at is timing,
      # so this asserts that it names one of them, not which.
      Application.put_env(:kiln_cms, Releases, Keyword.put(previous, :transaction_timeout_ms, 1))

      {:ok, failed} = go_live(rel, admin)

      assert failed.state == :failed
      assert failed.failed_item_id in [one.id, two.id]
      assert failed.failure_reason =~ "budget"

      # The bound is real, not decorative: nothing went live.
      assert reload_page(a).state == :draft
      assert reload_page(b).state == :draft
      assert [_, _] = CMS.list_release_items_with_status!(rel.id, :pending, authorize?: false)
    end

    test "a rollback is bounded the same way, and undoes nothing when it trips",
         %{previous: previous} do
      admin = user(:admin)
      rel = release(admin)
      # Two items, so the budget is spent undoing the first and the check before
      # the second one trips — with one item the whole rollback finishes inside
      # the budget no matter how small it is.
      a = page()
      b = page()
      {:ok, _} = add(rel, a, admin)
      {:ok, _} = add(rel, b, admin)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published
      assert reload_page(a).state == :published
      assert reload_page(b).state == :published

      Application.put_env(:kiln_cms, Releases, Keyword.put(previous, :transaction_timeout_ms, 1))

      {:ok, _} = CMS.start_release_rollback(published, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      after_attempt = reload(rel)
      assert after_attempt.state == :published
      assert after_attempt.failure_reason =~ "budget"

      # All-or-nothing applies to rollback too: the item that WAS undone before
      # the budget ran out went back up with everything else.
      assert reload_page(a).state == :published
      assert reload_page(b).state == :published
      assert [_, _] = CMS.list_release_items_with_status!(rel.id, :applied, authorize?: false)
    end

    test "a generous budget is not tripped by a normal release", %{previous: previous} do
      admin = user(:admin)
      rel = release(admin)
      p = page()
      {:ok, _} = add(rel, p, admin)

      Application.put_env(
        :kiln_cms,
        Releases,
        Keyword.put(previous, :transaction_timeout_ms, :timer.minutes(2))
      )

      {:ok, published} = go_live(rel, admin)
      assert published.state == :published
      assert reload_page(p).state == :published
    end
  end

  describe "changing an item's action in place" do
    test "an editor can flip publish to unpublish without freeing the reservation" do
      admin = user(:admin)
      editor = user(:editor)
      rel = release(admin)
      p = page(%{state: :published})
      {:ok, item} = add(rel, p, admin, :publish)

      {:ok, flipped} = CMS.set_release_item_action(item, %{action: :unpublish}, actor: editor)

      assert flipped.action == :unpublish
      assert flipped.status == :pending
      # The reservation never lapsed, so no other release could have taken it.
      assert [_] =
               CMS.list_pending_release_items_for_content!("page", p.id, authorize?: false)

      {:ok, published} = go_live(rel, admin)
      assert published.state == :published
      assert reload_page(p).state == :draft
    end

    test "a release that is no longer composing refuses the flip" do
      admin = user(:admin)
      rel = release(admin)
      p = page()
      {:ok, item} = add(rel, p, admin)
      {:ok, published} = go_live(rel, admin)
      assert published.state == :published

      assert {:error, _} = CMS.set_release_item_action(item, %{action: :unpublish}, actor: admin)
      assert CMS.get_release_item!(item.id, authorize?: false).action == :publish
    end

    test "an applied item's action is history and cannot be rewritten" do
      admin = user(:admin)
      rel = release(admin)
      {:ok, item} = add(rel, page(), admin)
      {:ok, _} = go_live(rel, admin)

      applied = CMS.get_release_item!(item.id, authorize?: false)
      assert applied.status == :applied

      assert {:error, _} =
               CMS.set_release_item_action(applied, %{action: :unpublish}, authorize?: false)
    end

    test "a viewer may not flip an item" do
      admin = user(:admin)
      viewer = user(:viewer)
      rel = release(admin)
      {:ok, item} = add(rel, page(), admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.set_release_item_action(item, %{action: :unpublish}, actor: viewer)
    end
  end
end
