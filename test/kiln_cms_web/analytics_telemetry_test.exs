defmodule KilnCMSWeb.AnalyticsTelemetryTest do
  @moduledoc """
  Delivering a published page emits `[:kiln_cms, :analytics, :view]` so external
  sinks (Prometheus, OTLP) can observe view traffic (#45).

  `async: false` deliberately: telemetry handlers are VM-global, so a sibling
  async test delivering a page would satisfy this test's `assert_receive` and
  make it pass for the wrong reason.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  # Forward one event to this process and detach when the test ends.
  defp listen do
    test_pid = self()
    handler_id = "test-analytics-view-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kiln_cms, :analytics, :view],
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp published_page do
    Ash.Seed.seed!(CMS.Page, %{
      title: "Telemetry Page",
      slug: "tel-#{System.unique_integer([:positive])}",
      state: :published
    })
  end

  test "delivering a published page emits a view event", %{conn: conn} do
    listen()
    page = published_page()

    conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert_receive {:telemetry, [:kiln_cms, :analytics, :view], measurements, metadata}
    assert measurements.count == 1
    assert metadata.type == "page"
    assert metadata.content_id == page.id
  end

  test "the event carries no tenant identifier", %{conn: conn} do
    listen()
    page = published_page()

    conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert_receive {:telemetry, [:kiln_cms, :analytics, :view], _measurements, metadata}

    # Privacy invariant: this metadata can reach Sentry/OTLP exporters, so the
    # org identifier is deliberately omitted. Asserted explicitly because adding
    # it back would otherwise regress silently.
    refute Map.has_key?(metadata, :org_id)
  end

  test "the event has a matching Telemetry.Metrics definition" do
    # An event with no entry in `metrics/0` surfaces nowhere — not on
    # LiveDashboard, not in a Prometheus export.
    assert Enum.any?(
             KilnCMSWeb.Telemetry.metrics(),
             &(&1.name == [:kiln_cms, :analytics, :view, :count])
           )
  end

  # A published page with its artifact fired, so the headless endpoint serves it
  # rather than answering 503 while it compiles (#208).
  defp fired_page do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "tel-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    page =
      CMS.create_page!(
        %{
          title: "Surface",
          slug: "surf-#{System.unique_integer([:positive])}",
          blocks: [%{type: :heading, content: "Hi", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    page = CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    page
  end

  describe "delivery surface" do
    test "the rendered site tags itself html", %{conn: conn} do
      listen()
      page = published_page()

      conn |> get(~p"/#{page.slug}") |> html_response(200)

      assert_receive {:telemetry, [:kiln_cms, :analytics, :view], _measurements, metadata}
      assert metadata.surface == "html"
    end

    # The tag is what keeps a mixed counter interpretable: the stored counters
    # have no surface dimension, so without it there is no way to tell a
    # headless site's traffic from the rendered site's.
    test "a headless artifact fetch tags the surface it served", %{conn: conn} do
      listen()
      page = fired_page()

      conn |> get(~p"/api/content/page/#{page.slug}?surface=json_ld") |> json_response(200)

      assert_receive {:telemetry, [:kiln_cms, :analytics, :view], _measurements, metadata}
      assert metadata.type == "page"
      assert metadata.surface == "json_ld"
    end
  end
end
