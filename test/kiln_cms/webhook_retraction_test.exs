defmodule KilnCMS.WebhookRetractionTest do
  @moduledoc """
  #1926: a retraction delivery (`unpublished`, `archived`, `deleted`) cannot be
  lost to endpoint auto-disable. It reaches an auto-disabled endpoint, retries
  on its own longer schedule, never counts against the endpoint, and when it
  does exhaust it is surfaced: a console notice to the site's admins and a row
  on the document's governance trail.
  """
  # async: false — tweaks the global auto-disable threshold via app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  alias KilnCMS.CMS
  alias KilnCMS.Governance
  alias KilnCMS.Notifications
  alias KilnCMS.Webhooks
  alias KilnCMS.Webhooks.DeliveryWorker

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Webhooks, original) end)
    :ok
  end

  defp put_webhook_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])
    Application.put_env(:kiln_cms, KilnCMS.Webhooks, Keyword.merge(base, overrides))
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "retract-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Long enough to be masked to its last four (#2245): the notice, the log
  # and the trail name the endpoint without its secret segment.
  @hook_url "https://example.test/hook/T0SECRET-token-Zq9x"
  @masked_url "https://example.test/…/Zq9x"
  @secret_segment "T0SECRET-token"

  defp endpoint!(attrs \\ %{}) do
    CMS.create_webhook_endpoint!(
      Map.merge(%{url: @hook_url}, attrs),
      actor: admin()
    )
  end

  defp reload(endpoint), do: CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)

  # A receiver that answers `status` and reports every event it was sent.
  defp stub_status(status) do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      send(test_pid, {:delivered, Plug.Conn.get_req_header(conn, Webhooks.event_header())})
      Plug.Conn.send_resp(conn, status, "{}")
    end)
  end

  defp drain_with_retries do
    Oban.drain_queue(queue: :webhooks, with_scheduled: true, with_recursion: true)
  end

  defp deliveries, do: CMS.recent_webhook_deliveries!(authorize?: false)

  # An endpoint the pipeline switched off: what `record_delivery_failure` leaves
  # behind once the run of failures reaches the threshold.
  defp auto_disabled_endpoint! do
    put_webhook_env(auto_disable_after: 1)
    endpoint = endpoint!()
    CMS.record_webhook_failure!(endpoint, %{}, authorize?: false)
    endpoint = reload(endpoint)
    refute endpoint.active
    assert endpoint.auto_disabled_at
    endpoint
  end

  describe "retraction?/1" do
    test "is the three withdrawing verbs on a content event" do
      assert Webhooks.retraction?("page.unpublished")
      assert Webhooks.retraction?("recipe.archived")
      assert Webhooks.retraction?("post.deleted")

      refute Webhooks.retraction?("page.published")
      refute Webhooks.retraction?("page.updated")
      refute Webhooks.retraction?("page.restored")
      refute Webhooks.retraction?("release.failed")
      refute Webhooks.retraction?("ping")
    end

    test "the ledger flags a retraction at create, from the event alone" do
      endpoint = endpoint!()

      retraction =
        CMS.create_webhook_delivery!(
          %{endpoint_id: endpoint.id, event: "page.unpublished", payload: %{}},
          authorize?: false
        )

      ordinary =
        CMS.create_webhook_delivery!(
          %{endpoint_id: endpoint.id, event: "page.updated", payload: %{}},
          authorize?: false
        )

      assert retraction.retraction
      refute ordinary.retraction
    end
  end

  describe "the retry schedule" do
    test "is longer than an ordinary delivery's, and about a day" do
      assert Webhooks.retraction_max_attempts() > 5

      total =
        Enum.sum(
          for n <- 1..(Webhooks.retraction_max_attempts() - 1), do: Webhooks.retraction_backoff(n)
        )

      assert total >= 18 * 3600
      assert total <= 36 * 3600
      assert Webhooks.retraction_backoff(1) == 30
      assert Webhooks.retraction_backoff(50) == 3600
    end

    test "a retraction job carries its own attempt budget and backoff" do
      endpoint!()
      stub_status(200)

      Webhooks.dispatch("page.unpublished", %{"id" => Ecto.UUID.generate()})
      Webhooks.dispatch("page.updated", %{"id" => Ecto.UUID.generate()})

      jobs = all_enqueued(worker: DeliveryWorker)
      retraction = Enum.find(jobs, &(&1.args["retraction"] == true))
      ordinary = Enum.find(jobs, &is_nil(&1.args["retraction"]))

      assert retraction.max_attempts == Webhooks.retraction_max_attempts()
      assert ordinary.max_attempts == 5

      assert DeliveryWorker.backoff(%{retraction | attempt: 3}) == Webhooks.retraction_backoff(3)
    end
  end

  test "a retraction reaches an auto-disabled endpoint, an ordinary event does not" do
    endpoint = auto_disabled_endpoint!()
    stub_status(200)

    Webhooks.dispatch("page.updated", %{"id" => Ecto.UUID.generate()})
    Webhooks.dispatch("page.unpublished", %{"id" => Ecto.UUID.generate()})
    drain_with_retries()

    assert_received {:delivered, ["page.unpublished"]}
    refute_received {:delivered, ["page.updated"]}

    assert [%{event: "page.unpublished", status: :succeeded} = delivery] = deliveries()
    assert delivery.delivered_at

    # Getting through is not the admin's "this receiver is back": the endpoint
    # stays auto-disabled, so the next retraction still reaches it.
    endpoint = reload(endpoint)
    refute endpoint.active
    assert endpoint.auto_disabled_at
  end

  test "an endpoint an admin switched off receives no retraction" do
    endpoint!(%{active: false})
    stub_status(200)

    Webhooks.dispatch("page.unpublished", %{"id" => Ecto.UUID.generate()})
    drain_with_retries()

    refute_received {:delivered, _}
    assert deliveries() == []
  end

  test "an exhausted retraction does not count towards auto-disable" do
    put_webhook_env(auto_disable_after: 1)
    endpoint = endpoint!()
    stub_status(503)

    Webhooks.dispatch("page.unpublished", %{"id" => Ecto.UUID.generate(), "title" => "Dosage"})
    drain_with_retries()

    assert [delivery] = deliveries()
    assert delivery.status == :failed
    assert delivery.attempts == Webhooks.retraction_max_attempts()

    endpoint = reload(endpoint)
    assert endpoint.active
    assert endpoint.consecutive_failures == 0
  end

  describe "an exhausted retraction is surfaced" do
    setup do
      admin = admin()

      page =
        CMS.create_page!(
          %{title: "Dosage guidance", slug: "dosage-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      page = CMS.publish_page!(page, %{}, actor: admin)
      endpoint = endpoint!()
      %{admin: admin, page: page, endpoint: endpoint}
    end

    test "as a console notice to the site's admins, linking to the trail", %{
      admin: admin,
      page: page
    } do
      stub_status(500)

      CMS.unpublish_page!(page, %{}, actor: admin)

      log = ExUnit.CaptureLog.capture_log(fn -> drain_with_retries() end)
      assert log =~ "#{@masked_url} exhausted its retries"
      refute log =~ @secret_segment

      org = KilnCMS.Accounts.default_org_id()

      assert [notice] =
               admin
               |> Notifications.recent(org, 10)
               |> Enum.filter(&(&1.event == :retraction_lost))

      assert notice.content_type == "page"
      assert notice.content_id == page.id
      assert notice.title == "Dosage guidance"
      assert notice.excerpt =~ @masked_url
      refute notice.excerpt =~ @secret_segment
      assert notice.excerpt =~ "HTTP 500"
      assert KilnCMSWeb.NotificationText.headline(notice) == "Retraction not delivered"

      assert KilnCMS.Notifications.Link.editor_path(notice) ==
               "/editor/governance/page/#{page.id}"
    end

    test "as a row on the document's governance trail, until a replay gets through", %{
      admin: admin,
      page: page,
      endpoint: endpoint
    } do
      stub_status(500)
      CMS.unpublish_page!(page, %{}, actor: admin)
      drain_with_retries()

      org = KilnCMS.Accounts.default_org_id()
      assert [lost] = Governance.trail("page", page.id, org).lost_retractions
      assert lost.event == "page.unpublished"
      assert lost.endpoint_url == @masked_url
      assert lost.attempts == Webhooks.retraction_max_attempts()
      assert lost.last_error =~ "HTTP 500"
      assert lost.recovered_at == nil

      # The receiver is fixed and the admin replays it from /editor/webhooks.
      stub_status(200)
      failed = Enum.find(deliveries(), &(&1.status == :failed))
      Webhooks.redeliver(failed)
      drain_with_retries()

      assert [lost] = Governance.trail("page", page.id, org).lost_retractions
      assert %DateTime{} = lost.recovered_at
    end

    test "for a trashed document too, whose trail stays reachable", %{
      admin: admin,
      page: page
    } do
      stub_status(500)
      CMS.destroy_page!(page, actor: admin)
      drain_with_retries()

      org = KilnCMS.Accounts.default_org_id()
      trail = Governance.trail("page", page.id, org)

      assert trail.item.trashed?
      events = trail.lost_retractions |> Enum.map(& &1.event) |> Enum.sort()
      assert "page.deleted" in events
    end
  end

  test "a failed retraction outlives the ledger's retention window, its body does not" do
    endpoint = endpoint!()
    old = DateTime.add(DateTime.utc_now(), -(CMS.WebhookDelivery.retention_days() + 1), :day)
    doc_id = Ecto.UUID.generate()

    seed = fn event, status ->
      delivery =
        CMS.create_webhook_delivery!(
          %{
            endpoint_id: endpoint.id,
            event: event,
            payload: %{"id" => doc_id, "slug" => "withdrawn", "body" => "the withdrawn text"}
          },
          authorize?: false
        )

      KilnCMS.Repo.query!(
        "UPDATE webhook_deliveries SET status = $1, inserted_at = $2 WHERE id = $3",
        [to_string(status), old, Ecto.UUID.dump!(delivery.id)]
      )

      delivery
    end

    lost = seed.("page.unpublished", :failed)
    delivered = seed.("page.unpublished", :succeeded)
    ordinary = seed.("page.updated", :failed)

    AshOban.schedule_and_run_triggers(CMS.WebhookDelivery,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    ids = Enum.map(deliveries(), & &1.id)
    assert lost.id in ids
    refute delivered.id in ids
    refute ordinary.id in ids

    kept = CMS.get_webhook_delivery!(lost.id, authorize?: false)
    assert kept.payload == %{"id" => doc_id, "slug" => "withdrawn"}
    assert kept.payload_scrubbed_at
    assert kept.document_id == doc_id
  end

  test "trashing or archiving a draft is not a retraction" do
    admin = admin()
    endpoint = auto_disabled_endpoint!()
    stub_status(500)

    draft =
      CMS.create_page!(
        %{title: "Never live", slug: "never-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.destroy_page!(draft, actor: admin)
    drain_with_retries()

    # A draft's tombstone goes nowhere an auto-disabled endpoint would only
    # take for a retraction, and nothing is surfaced.
    refute_received {:delivered, _}
    assert deliveries() == []

    assert Governance.trail("page", draft.id, KilnCMS.Accounts.default_org_id()).lost_retractions ==
             []

    assert reload(endpoint).auto_disabled_at
  end

  test "a draft's tombstone to an active endpoint is an ordinary delivery" do
    admin = admin()
    endpoint!()
    stub_status(200)

    draft =
      CMS.create_page!(%{title: "Draft", slug: "draft-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.destroy_page!(draft, actor: admin)
    drain_with_retries()

    assert [%{event: "page.deleted", retraction: false}] = deliveries()
  end

  test "a retraction in flight to an endpoint an admin then switched off is surfaced" do
    admin = admin()
    endpoint = endpoint!()
    stub_status(200)

    Webhooks.dispatch("page.unpublished", %{"id" => Ecto.UUID.generate(), "title" => "Gone"})
    CMS.update_webhook_endpoint!(endpoint, %{active: false}, actor: admin)
    drain_with_retries()

    refute_received {:delivered, _}
    assert [%{status: :failed, last_error: "endpoint inactive"}] = deliveries()

    assert Enum.any?(
             Notifications.recent(admin, KilnCMS.Accounts.default_org_id(), 10),
             &(&1.event == :retraction_lost)
           )
  end

  describe "the endpoint's auto-disable stamp" do
    test "survives an admin edit that leaves it off, and clears when it is turned on" do
      admin = admin()
      endpoint = auto_disabled_endpoint!()

      endpoint =
        CMS.update_webhook_endpoint!(endpoint, %{url: "https://example.test/fixed"}, actor: admin)

      refute endpoint.active
      assert endpoint.auto_disabled_at

      endpoint = CMS.update_webhook_endpoint!(endpoint, %{active: true}, actor: admin)
      assert endpoint.active
      assert is_nil(endpoint.auto_disabled_at)
    end

    test "is not cleared by a success recorded against a stale active copy" do
      endpoint = endpoint!()
      stale_copy = endpoint

      # Another delivery exhausts and auto-disables the endpoint after this
      # job read it…
      put_webhook_env(auto_disable_after: 1)
      CMS.record_webhook_failure!(endpoint, %{}, authorize?: false)

      # …and this job's POST then succeeds.
      CMS.record_webhook_success!(stale_copy, %{}, authorize?: false)

      endpoint = reload(endpoint)
      refute endpoint.active
      assert endpoint.auto_disabled_at
    end
  end

  describe "recovery" do
    setup do
      admin = admin()

      page =
        CMS.create_page!(%{title: "Recall", slug: "recall-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      %{admin: admin, page: CMS.publish_page!(page, %{}, actor: admin)}
    end

    test "a later retraction of the same document under another verb recovers the loss", %{
      admin: admin,
      page: page
    } do
      endpoint!()
      stub_status(500)
      CMS.unpublish_page!(page, %{}, actor: admin)
      drain_with_retries()

      org = KilnCMS.Accounts.default_org_id()

      assert [%{event: "page.unpublished", recovered_at: nil}] =
               Governance.trail("page", page.id, org).lost_retractions

      stub_status(200)
      page = CMS.get_page!(page.id, authorize?: false)
      CMS.destroy_page!(page, actor: admin)
      drain_with_retries()

      assert [%{event: "page.unpublished", recovered_at: %DateTime{}}] =
               Governance.trail("page", page.id, org).lost_retractions
    end

    test "outlives the prune of the delivery that recovered it", %{admin: admin, page: page} do
      endpoint!()
      stub_status(500)
      CMS.unpublish_page!(page, %{}, actor: admin)
      drain_with_retries()

      stub_status(200)
      failed = Enum.find(deliveries(), &(&1.status == :failed))
      replay = Webhooks.redeliver(failed)
      drain_with_retries()

      old = DateTime.add(DateTime.utc_now(), -(CMS.WebhookDelivery.retention_days() + 1), :day)

      KilnCMS.Repo.query!("UPDATE webhook_deliveries SET inserted_at = $1", [old])

      AshOban.schedule_and_run_triggers(CMS.WebhookDelivery,
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )

      refute replay.id in Enum.map(deliveries(), & &1.id)

      org = KilnCMS.Accounts.default_org_id()

      assert [%{recovered_at: %DateTime{}}] =
               Governance.trail("page", page.id, org).lost_retractions
    end
  end

  test "deleting the endpoint keeps the lost retraction on the trail, named" do
    admin = admin()

    page =
      CMS.create_page!(%{title: "Kept", slug: "kept-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    endpoint = endpoint!()
    stub_status(500)
    CMS.unpublish_page!(page, %{}, actor: admin)
    drain_with_retries()

    CMS.destroy_webhook_endpoint!(endpoint, actor: admin)

    assert [lost] =
             Governance.trail("page", page.id, KilnCMS.Accounts.default_org_id()).lost_retractions

    assert lost.endpoint_url == @masked_url
    assert is_nil(lost.endpoint_id)

    failed = CMS.get_webhook_delivery!(lost.id, authorize?: false)
    # The ledger keeps the real URL (#2245): masking is for display.
    assert failed.endpoint_url == endpoint.url
    assert Webhooks.redeliver(failed) == {:error, :endpoint_deleted}
  end

  test "an endpoint auto-disabled past the stale window gets one attempt and no notice" do
    admin = admin()
    endpoint = auto_disabled_endpoint!()

    long_ago =
      DateTime.add(DateTime.utc_now(), -(Webhooks.retraction_stale_after_days() + 1), :day)

    KilnCMS.Repo.query!("UPDATE webhook_endpoints SET auto_disabled_at = $1 WHERE id = $2", [
      long_ago,
      Ecto.UUID.dump!(endpoint.id)
    ])

    stub_status(503)
    Webhooks.dispatch("page.unpublished", %{"id" => Ecto.UUID.generate(), "title" => "Bulk"})
    drain_with_retries()

    assert [%{status: :failed, attempts: 1}] = deliveries()

    refute Enum.any?(
             Notifications.recent(admin, KilnCMS.Accounts.default_org_id(), 10),
             &(&1.event == :retraction_lost)
           )
  end
end
