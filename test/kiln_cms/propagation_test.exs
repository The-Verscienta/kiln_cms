defmodule KilnCMS.PropagationTest do
  @moduledoc """
  #1927: one propagation record per publish or withdrawal, settled once every
  webhook endpoint is terminal and the CDN purge is not pending, with the
  latencies `percentiles/2` and `mix kiln.propagation` report.
  """
  # async: false — sets the global `KilnCMS.CDN` and `KilnCMS.Webhooks` env,
  # and attaches a telemetry handler.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  alias KilnCMS.CDN
  alias KilnCMS.CMS
  alias KilnCMS.Propagation

  setup do
    cdn = Application.get_env(:kiln_cms, CDN, [])
    webhooks = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, CDN, cdn)
      Application.put_env(:kiln_cms, KilnCMS.Webhooks, webhooks)
    end)

    Application.put_env(:kiln_cms, CDN, Keyword.put(cdn, :purge_url, nil))

    test_pid = self()
    handler = "propagation-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Propagation.telemetry_event(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:propagation, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp org, do: KilnCMS.Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "prop-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp endpoint!(url \\ "https://example.test/hook") do
    CMS.create_webhook_endpoint!(%{url: url}, actor: admin())
  end

  defp published_page!(admin) do
    page =
      CMS.create_page!(%{title: "Dose", slug: "dose-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.publish_page!(page, %{}, actor: admin)
  end

  defp stub(status_fun) do
    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      Plug.Conn.send_resp(conn, status_fun.(conn.host), "{}")
    end)
  end

  defp drain,
    do: Oban.drain_queue(queue: :webhooks, with_scheduled: true, with_recursion: true)

  defp records,
    do: CMS.list_propagations!(authorize?: false, query: [sort: [transitioned_at: :asc]])

  defp records(kind), do: Enum.filter(records(), &(&1.kind == kind))

  describe "kind/2" do
    test "publishes and withdrawals are transitions; nothing else is" do
      assert Propagation.kind("page.published", false) == :publish
      assert Propagation.kind("page.unpublished", true) == :withdraw
      assert Propagation.kind("page.deleted", true) == :withdraw

      # A draft's tombstone took nothing off a consumer.
      assert Propagation.kind("page.deleted", false) == nil
      # Archiving a live document also fires `unpublished`, the one measured.
      assert Propagation.kind("page.archived", true) == nil
      assert Propagation.kind("page.updated", true) == nil
      assert Propagation.kind("ping", true) == nil
    end

    test "a domain event sharing a verb is not a document's transition" do
      assert Propagation.open(
               "release.published",
               %{"id" => Ecto.UUID.generate()},
               org(),
               true,
               0
             ) ==
               nil

      assert records() == []
    end
  end

  # Archiving a dynamic type keeps its entries firing `<name>.*` (#938), and
  # webhooks deliver those; the registry lookup `open/5` used to gate on
  # leaves archived types out, so their transitions went unmeasured.
  test "an entry of an archived dynamic type is still measured" do
    admin = admin()
    stub(fn _host -> 200 end)

    definition =
      CMS.create_type_definition!(
        %{name: "remedy#{System.unique_integer([:positive])}", label: "Remedy"},
        actor: admin
      )

    entry =
      CMS.ContentTypes.create!(
        definition.name,
        %{title: "Ginger", slug: "ginger-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["#{definition.name}.unpublished"]},
      actor: admin
    )

    {:ok, entry} = CMS.ContentTypes.transition(definition.name, "publish", entry, actor: admin)
    drain()

    CMS.destroy_type_definition!(definition, actor: admin)
    assert CMS.ContentTypes.get(definition.name, org()) == nil

    CMS.unpublish_entry!(entry, %{}, actor: admin)
    drain()

    assert [withdrawal] = records(:withdraw)
    assert withdrawal.event == "#{definition.name}.unpublished"
    assert withdrawal.document_type == definition.name
    assert withdrawal.document_id == entry.id
    assert withdrawal.endpoints_expected == 1
    assert %DateTime{} = withdrawal.completed_at
  end

  test "an unpublish reaching two endpoints settles once, with the last endpoint's time" do
    admin = admin()
    endpoint!("https://one.test/hook")
    endpoint!("https://two.test/hook")
    stub(fn _host -> 200 end)
    page = published_page!(admin)
    drain()

    CMS.unpublish_page!(page, %{}, actor: admin)
    drain()

    assert [withdrawal] = records(:withdraw)
    assert withdrawal.event == "page.unpublished"
    assert withdrawal.document_id == page.id
    assert withdrawal.endpoints_expected == 2
    assert withdrawal.endpoints_failed == 0
    assert withdrawal.cdn_status == :not_configured
    assert %DateTime{} = withdrawal.completed_at

    deliveries =
      CMS.list_webhook_deliveries!(authorize?: false)
      |> Enum.filter(&(&1.propagation_id == withdrawal.id))

    assert length(deliveries) == 2
    last = deliveries |> Enum.map(& &1.delivered_at) |> Enum.max(DateTime)

    assert withdrawal.endpoint_latency_ms ==
             DateTime.diff(last, withdrawal.transitioned_at, :millisecond)

    assert_received {:propagation, %{endpoint_latency_ms: ms, endpoints: 2, endpoints_failed: 0},
                     %{kind: :withdraw, event: "page.unpublished"}}

    assert ms == withdrawal.endpoint_latency_ms
    # One event per record: the publish before it and this withdrawal.
    refute_received {:propagation, _, %{kind: :withdraw}}
  end

  test "a lost endpoint settles the record without a latency, and counts as lost" do
    admin = admin()
    endpoint!("https://good.test/hook")
    endpoint!("https://dead.test/hook")

    stub(fn
      "dead.test" -> 503
      _ -> 200
    end)

    page = published_page!(admin)
    drain()

    CMS.unpublish_page!(page, %{}, actor: admin)
    drain()

    assert [withdrawal] = records(:withdraw)
    assert withdrawal.completed_at
    assert withdrawal.endpoints_failed == 1
    assert withdrawal.endpoint_latency_ms == nil

    assert_received {:propagation, measurements, %{kind: :withdraw}}
    refute Map.has_key?(measurements, :endpoint_latency_ms)

    stats = Propagation.percentiles(org(), kind: :withdraw)
    assert %{count: 0, lost: 1, open: 0, p95_ms: nil} = stats
  end

  test "a transition sent nowhere settles at once" do
    admin = admin()
    published_page!(admin)

    assert [publish] = records(:publish)
    assert publish.endpoints_expected == 0
    assert publish.completed_at
    assert publish.endpoint_latency_ms == nil
    assert %{no_endpoints: 1, count: 0} = Propagation.percentiles(org(), kind: :publish)
  end

  test "edits to live content and a draft's trash open no record" do
    admin = admin()
    endpoint!()
    stub(fn _host -> 200 end)
    page = published_page!(admin)
    CMS.update_page!(page, %{title: "Dose, revised"}, actor: admin)

    draft =
      CMS.create_page!(%{title: "Draft", slug: "draft-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.destroy_page!(draft, actor: admin)
    drain()

    assert [%{kind: :publish}] = records()
  end

  test "trashing a live document is a withdrawal; archiving one is measured once" do
    admin = admin()
    trashed = published_page!(admin)
    archived = published_page!(admin)

    CMS.destroy_page!(trashed, actor: admin)
    CMS.archive_page!(archived, %{}, actor: admin)

    withdrawals = records(:withdraw)

    assert Enum.map(withdrawals, & &1.event) |> Enum.sort() == [
             "page.deleted",
             "page.unpublished"
           ]

    assert Enum.map(withdrawals, & &1.document_id) |> Enum.sort() ==
             Enum.sort([trashed.id, archived.id])
  end

  describe "with a CDN purge configured" do
    setup do
      Application.put_env(
        :kiln_cms,
        CDN,
        Keyword.put(Application.get_env(:kiln_cms, CDN, []), :purge_url, "https://purge.test/p")
      )

      :ok
    end

    test "waits for the purge, and one purge settles every transition it covers" do
      admin = admin()
      Req.Test.stub(CDN, &Plug.Conn.send_resp(&1, 200, "{}"))

      first = published_page!(admin)
      second = published_page!(admin)

      assert [_, _] = pending = records(:publish)
      assert Enum.all?(pending, &(&1.cdn_status == :pending and is_nil(&1.completed_at)))

      drain()

      assert [_, _] = settled = records(:publish)

      for record <- settled do
        assert record.cdn_status == :acknowledged
        assert record.completed_at

        assert record.cdn_latency_ms ==
                 DateTime.diff(record.cdn_settled_at, record.transitioned_at, :millisecond)
      end

      assert Enum.map(settled, & &1.document_id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])
    end

    test "an endpoint answering first does not settle it while the purge is pending" do
      admin = admin()
      endpoint!()
      stub(fn _host -> 200 end)
      Req.Test.stub(CDN, &Plug.Conn.send_resp(&1, 200, "{}"))
      published_page!(admin)

      # The delivery runs now; the purge is scheduled a moment out.
      Oban.drain_queue(queue: :webhooks)

      assert [publish] = records(:publish)
      assert publish.cdn_status == :pending
      assert publish.completed_at == nil

      drain()

      assert [publish] = records(:publish)
      assert publish.cdn_status == :acknowledged
      assert publish.completed_at
      assert is_integer(publish.endpoint_latency_ms)
    end

    test "a purge that gives up still settles the record" do
      admin = admin()
      Req.Test.stub(CDN, &Plug.Conn.send_resp(&1, 503, ""))
      published_page!(admin)

      drain()

      assert [publish] = records(:publish)
      assert publish.cdn_status == :failed
      assert publish.completed_at
      assert publish.cdn_latency_ms == nil
    end
  end

  test "settling twice stamps and reports once" do
    admin = admin()
    published_page!(admin)
    [publish] = records(:publish)
    assert_received {:propagation, _, %{kind: :publish}}

    assert Propagation.settle(publish.id, publish.org_id) == :ok
    refute_received {:propagation, _, _}

    assert CMS.get_propagation!(publish.id, authorize?: false).completed_at ==
             publish.completed_at
  end

  describe "percentiles/2" do
    test "is nearest-rank over the measured latencies, and counts what is still open" do
      now = DateTime.utc_now()

      for ms <- [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000] do
        seed!(kind: :withdraw, completed_at: now, endpoint_latency_ms: ms, endpoints_failed: 0)
      end

      seed!(kind: :withdraw, completed_at: nil)
      # Outside the window.
      seed!(
        kind: :withdraw,
        completed_at: DateTime.add(now, -30, :day),
        transitioned_at: DateTime.add(now, -30, :day),
        endpoint_latency_ms: 99_999
      )

      assert %{count: 10, p50_ms: 500, p95_ms: 1000, max_ms: 1000, open: 1, lost: 0} =
               Propagation.percentiles(org(), kind: :withdraw)
    end

    test "nearest_rank/2" do
      assert Propagation.nearest_rank([], 95) == nil
      assert Propagation.nearest_rank([7], 95) == 7
      assert Propagation.nearest_rank(Enum.to_list(1..20), 95) == 19
      assert Propagation.nearest_rank(Enum.to_list(1..20), 50) == 10
    end

    defp seed!(attrs) do
      now = DateTime.utc_now()

      Ash.Seed.seed!(
        CMS.Propagation,
        Map.merge(
          %{
            org_id: org(),
            kind: :withdraw,
            event: "page.unpublished",
            document_type: "page",
            document_id: Ecto.UUID.generate(),
            transitioned_at: now,
            endpoints_expected: 1
          },
          Map.new(attrs)
        )
      )
    end
  end

  test "the mix task prints one line per kind" do
    line =
      Mix.Tasks.Kiln.Propagation.line(%{
        kind: :withdraw,
        count: 42,
        p50_ms: 380,
        p95_ms: 1920,
        max_ms: 4100,
        lost: 0,
        no_endpoints: 3,
        open: 1
      })

    assert line ==
             "withdraw   n=42  p50=0.38s  p95=1.92s  max=4.10s  lost=0  no-endpoints=3  open=1"
  end
end
