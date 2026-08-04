defmodule KilnCMSWeb.CalendarControllerTest do
  @moduledoc """
  The public `.ics` delivery surface (#480).

  The tests that matter here are the ones about what a calendar must *not*
  carry: a subscribed calendar is fetched by an anonymous client on a timer,
  forever, so "published but audience-gated" leaking into one is a slow leak
  nobody notices.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  @london "Europe/London"

  setup %{conn: conn} do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "cal-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    name = "gig#{System.unique_integer([:positive])}"

    td =
      CMS.create_type_definition!(
        %{name: name, label: "Gig", plural_label: name, path_segment: name},
        actor: admin
      )

    CMS.create_field_definition!(
      %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
      actor: admin
    )

    %{conn: conn, admin: admin, td: td, plural: name, org: KilnCMS.Accounts.default_org_id()}
  end

  defp event!(ctx, attrs) do
    CMS.create_entry!(
      Map.merge(
        %{
          title: "A gig",
          slug: "ev-#{System.unique_integer([:positive])}",
          type_definition_id: ctx.td.id,
          custom_fields: %{
            "when" => %{"start" => "2026-03-15T19:00", "time_zone" => @london}
          }
        },
        attrs
      ),
      actor: ctx.admin
    )
  end

  defp publish!(record, ctx) do
    CMS.publish_entry!(record, actor: ctx.admin)
  end

  describe "a type's calendar" do
    test "serves published events as text/calendar", %{conn: conn} = ctx do
      ctx |> event!(%{title: "The gig"}) |> publish!(ctx)

      conn = get(conn, "/#{ctx.plural}/calendar.ics")

      assert response_content_type(conn, :ics) =~ "text/calendar"
      body = response(conn, 200)
      assert body =~ "BEGIN:VCALENDAR"
      assert body =~ "SUMMARY:The gig"
    end

    test "an unpublished draft is not in it", %{conn: conn} = ctx do
      event!(ctx, %{title: "Still a draft"})

      body = conn |> get("/#{ctx.plural}/calendar.ics") |> response(200)
      refute body =~ "Still a draft"
    end

    test "a published but audience-gated event is not in it", %{conn: conn} = ctx do
      # The read policy returns this to an actor-less caller — it is published.
      # It is *not* public, and a calendar is anonymous forever.
      ctx |> event!(%{title: "Members only", audience: :member}) |> publish!(ctx)

      body = conn |> get("/#{ctx.plural}/calendar.ics") |> response(200)
      refute body =~ "Members only"
    end

    test "a type with no schedule field has no calendar at all", %{conn: conn} = ctx do
      CMS.create_type_definition!(
        %{
          name: "plain#{System.unique_integer([:positive])}",
          label: "Plain",
          plural_label: "plain"
        },
        actor: ctx.admin
      )

      # 404, not an empty VCALENDAR — an empty calendar is a client subscribing
      # to nothing forever with no way to tell.
      assert conn |> get("/plain/calendar.ics") |> response(404)
    end
  end

  describe "one document's .ics" do
    test "downloads with a filename derived from the slug", %{conn: conn} = ctx do
      ctx |> event!(%{title: "The gig", slug: "the-gig-2026"}) |> publish!(ctx)

      conn = get(conn, "/#{ctx.plural}/the-gig-2026/calendar.ics")

      assert response(conn, 200) =~ "SUMMARY:The gig"

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition == ~s(attachment; filename="the-gig-2026.ics")
    end

    test "an audience-gated document 404s rather than downloading", %{conn: conn} = ctx do
      ctx
      |> event!(%{title: "Members only", slug: "members-2026", audience: :member})
      |> publish!(ctx)

      assert conn |> get("/#{ctx.plural}/members-2026/calendar.ics") |> response(404)
    end

    test "an unknown slug 404s", %{conn: conn} = ctx do
      assert conn |> get("/#{ctx.plural}/nope/calendar.ics") |> response(404)
    end
  end

  describe "a tag's calendar" do
    test "carries only events with that tag", %{conn: conn} = ctx do
      tag = CMS.create_tag!(%{name: "Jazz", slug: "jazz"}, actor: ctx.admin)

      tagged = event!(ctx, %{title: "Jazz night", tag_ids: [tag.id]})
      publish!(tagged, ctx)
      ctx |> event!(%{title: "Folk night"}) |> publish!(ctx)

      body = conn |> get("/#{ctx.plural}/tags/jazz/calendar.ics") |> response(200)

      assert body =~ "Jazz night"
      refute body =~ "Folk night"
    end

    test "an unknown tag 404s before anything is cached", %{conn: conn} = ctx do
      assert conn |> get("/#{ctx.plural}/tags/nope/calendar.ics") |> response(404)
    end
  end

  describe "the site-wide calendar" do
    test "mixes every event-shaped type", %{conn: conn} = ctx do
      ctx |> event!(%{title: "The gig"}) |> publish!(ctx)

      body = conn |> get("/calendar.ics") |> response(200)
      assert body =~ "SUMMARY:The gig"
    end
  end
end
