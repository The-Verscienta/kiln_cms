defmodule KilnCMSWeb.EventIndexTest do
  @moduledoc """
  The occurrence-sorted delivery index (#766) — `/<plural>` and
  `/<plural>/index.json`.

  Two families of test, and only one of them is about ordering. The other is the
  one that matters more: an index is an anonymous public route, so *published
  but gated* and *published but passphrase-locked* leaking into it is the same
  slow leak `CalendarControllerTest` guards the `.ics` routes against. #766 said
  in as many words that the filter must be identical to the calendar's, so both
  surfaces are asserted here rather than trusted to a shared function.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Events.Index

  @london "Europe/London"

  setup %{conn: conn} do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "eidx-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    name = "gig#{System.unique_integer([:positive])}"

    td =
      CMS.create_type_definition!(
        %{name: name, label: "Gigs", plural_label: name, path_segment: name},
        actor: admin
      )

    CMS.create_field_definition!(
      %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
      actor: admin
    )

    %{conn: conn, admin: admin, td: td, plural: name, org: KilnCMS.Accounts.default_org_id()}
  end

  # `days` from now, at whatever the current wall time is in London.
  defp schedule(days, opts \\ []) do
    start =
      DateTime.utc_now()
      |> DateTime.add(days * 86_400, :second)
      |> DateTime.shift_zone!(@london)
      |> DateTime.to_naive()

    %{"start" => NaiveDateTime.to_iso8601(start), "time_zone" => @london}
    |> Map.merge(Map.new(opts))
  end

  defp event!(ctx, title, days, attrs \\ %{}) do
    CMS.create_entry!(
      Map.merge(
        %{
          title: title,
          slug: "ev-#{System.unique_integer([:positive])}",
          type_definition_id: ctx.td.id,
          custom_fields: %{"when" => schedule(days)}
        },
        attrs
      ),
      actor: ctx.admin
    )
  end

  defp published!(ctx, title, days, attrs \\ %{}) do
    ctx |> event!(title, days, attrs) |> CMS.publish_entry!(actor: ctx.admin)
  end

  describe "the HTML index at /<plural>" do
    test "lists upcoming events soonest first", %{conn: conn} = ctx do
      published!(ctx, "Later gig", 30)
      published!(ctx, "Sooner gig", 2)

      body = conn |> get("/#{ctx.plural}") |> html_response(200)

      assert body =~ "Sooner gig"
      assert body =~ "Later gig"
      # The whole point of the feature: order, not membership.
      assert :binary.match(body, "Sooner gig") < :binary.match(body, "Later gig")
    end

    test "an event that has already happened is not on it", %{conn: conn} = ctx do
      # No apostrophes in these titles, deliberately: HEEx escapes `'` to
      # `&#39;`, so a `refute body =~ "Last year's gig"` would pass whether the
      # filter worked or not.
      published!(ctx, "A gig last year", -365)
      published!(ctx, "A gig next month", 30)

      body = conn |> get("/#{ctx.plural}") |> html_response(200)

      refute body =~ "A gig last year"
      assert body =~ "A gig next month"
    end

    test "a draft is not on it", %{conn: conn} = ctx do
      event!(ctx, "Still a draft", 5)

      refute conn |> get("/#{ctx.plural}") |> html_response(200) =~ "Still a draft"
    end

    test "a published but audience-gated event is not on it", %{conn: conn} = ctx do
      # Published — the read policy hands this to an actor-less caller. Not
      # public, and this route is anonymous.
      published!(ctx, "Members only", 5, %{audience: :member})
      published!(ctx, "Open to all", 6)

      body = conn |> get("/#{ctx.plural}") |> html_response(200)

      refute body =~ "Members only"
      assert body =~ "Open to all"
    end

    test "a passphrase-locked event is not on it", %{conn: conn} = ctx do
      ctx
      |> event!("Secret gig", 5)
      |> CMS.update_entry!(%{access_password: "hunter2hunter2"}, actor: ctx.admin)
      |> CMS.publish_entry!(actor: ctx.admin)

      refute conn |> get("/#{ctx.plural}") |> html_response(200) =~ "Secret gig"
    end

    test "a segment naming no event type still 404s as a missing page", %{conn: conn} do
      assert conn |> get("/definitely-not-a-type") |> response(404)
    end

    test "a REDIRECT at the same path still wins", %{conn: conn} = ctx do
      # The index is the last thing tried before the 404, after the alias and
      # the redirect table. An operator's explicit 301 must not be swallowed by
      # a listing that appeared because they added a schedule field.
      target =
        CMS.create_page!(
          %{title: "Elsewhere", slug: "elsewhere-#{System.unique_integer([:positive])}"},
          actor: ctx.admin
        )
        |> CMS.publish_page!(actor: ctx.admin)

      CMS.create_redirect!(
        %{path: "/#{ctx.plural}", locale: "en", target_type: "page", target_id: target.id},
        actor: ctx.admin
      )

      published!(ctx, "An indexed gig", 5)

      assert redirected_to(get(conn, "/#{ctx.plural}"), 301) == "/#{target.slug}"
    end

    test "a PAGE at the same slug wins, so the index can never take a URL away",
         %{conn: conn} = ctx do
      # Additive by construction: whatever answered at this URL before #766 must
      # keep answering. `Validations.SlugAvailable` already refuses a page slug
      # that collides with a live section URL, so this state is only reachable
      # the other way round — a type given the path segment of a page that
      # already exists — which the seed reproduces.
      assert {:error, _} = CMS.create_page(%{title: "Clash", slug: ctx.plural}, actor: ctx.admin)

      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Hand-built listing",
        slug: ctx.plural,
        locale: "en",
        state: :published,
        published_at: DateTime.utc_now(),
        org_id: ctx.org
      })

      published!(ctx, "An indexed gig", 5)

      body = conn |> get("/#{ctx.plural}") |> html_response(200)

      assert body =~ "Hand-built listing"
      refute body =~ "An indexed gig"
    end
  end

  describe "the JSON index at /<plural>/index.json" do
    test "carries the occurrence, not just the document", %{conn: conn} = ctx do
      published!(ctx, "The gig", 3)

      body = conn |> get("/#{ctx.plural}/index.json") |> json_response(200)

      assert [event] = body["events"]
      assert event["title"] == "The gig"
      assert {:ok, _starts, _} = DateTime.from_iso8601(event["starts_at"])
      assert event["time_zone"] == @london
      assert event["recurring"] == false
      assert event["url"] =~ "/#{ctx.plural}/"
    end

    test "ends_at is this occurrence's end", %{conn: conn} = ctx do
      start = schedule(3)
      finish = start["start"] |> NaiveDateTime.from_iso8601!() |> NaiveDateTime.add(7200, :second)

      event!(ctx, "Two hours", 3, %{
        custom_fields: %{"when" => Map.put(start, "end", NaiveDateTime.to_iso8601(finish))}
      })
      |> CMS.publish_entry!(actor: ctx.admin)

      assert [event] =
               conn |> get("/#{ctx.plural}/index.json") |> json_response(200) |> Map.get("events")

      {:ok, starts, _} = DateTime.from_iso8601(event["starts_at"])
      {:ok, ends, _} = DateTime.from_iso8601(event["ends_at"])
      assert DateTime.diff(ends, starts, :second) == 7200
    end

    test "soonest first, like the HTML index", %{conn: conn} = ctx do
      published!(ctx, "Later", 30)
      published!(ctx, "Sooner", 2)

      body = conn |> get("/#{ctx.plural}/index.json") |> json_response(200)

      assert Enum.map(body["events"], & &1["title"]) == ["Sooner", "Later"]
    end

    test "an audience-gated event is not in it either", %{conn: conn} = ctx do
      published!(ctx, "Members only", 5, %{audience: :member})

      body = conn |> get("/#{ctx.plural}/index.json") |> json_response(200)

      assert body["events"] == []
    end

    test "a type with no schedule field has no index at all", %{conn: conn} = ctx do
      plain =
        CMS.create_type_definition!(
          %{name: "plain#{System.unique_integer([:positive])}", label: "Plain"},
          actor: ctx.admin
        )

      # 404 rather than an empty document, for the reason the calendar 404s:
      # an index that will never have anything in it and no way to tell.
      assert conn |> get("/#{plain.path_segment}/index.json") |> json_response(404)
    end
  end

  describe "the window" do
    test "?until= bounds the far end, inclusively by date", %{conn: conn} = ctx do
      published!(ctx, "This week", 3)
      published!(ctx, "Next year", 300)

      until = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()
      body = conn |> get("/#{ctx.plural}/index.json?until=#{until}") |> json_response(200)

      assert Enum.map(body["events"], & &1["title"]) == ["This week"]
      assert body["until"]
    end

    test "?from= moves the near end", %{conn: conn} = ctx do
      published!(ctx, "Soon", 2)
      published!(ctx, "Later", 40)

      from = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()
      body = conn |> get("/#{ctx.plural}/index.json?from=#{from}") |> json_response(200)

      assert Enum.map(body["events"], & &1["title"]) == ["Later"]
    end

    test "both bounds at once really are both applied", %{conn: conn} = ctx do
      published!(ctx, "Too soon", 2)
      published!(ctx, "In the window", 20)
      published!(ctx, "Too late", 300)

      from = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()
      until = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      body =
        conn |> get("/#{ctx.plural}/index.json?from=#{from}&until=#{until}") |> json_response(200)

      # A keyword list holds a duplicate key perfectly happily, so a filter built
      # by concatenating the two bounds under the same key can silently apply
      # only one of them — and a one-sided window still looks like it worked.
      assert Enum.map(body["events"], & &1["title"]) == ["In the window"]
    end

    test "a bound with a wall time is read in the event zone, not as UTC",
         %{conn: conn} = ctx do
      published!(ctx, "Later today plus ten", 10)

      until = Date.utc_today() |> Date.add(11) |> Date.to_iso8601()

      body =
        conn |> get("/#{ctx.plural}/index.json?until=#{until}T23:59:59") |> json_response(200)

      assert Enum.map(body["events"], & &1["title"]) == ["Later today plus ten"]
    end

    test "?from= earlier than the anchor is clamped, and the response says so",
         %{conn: conn} = ctx do
      published!(ctx, "Soon", 2)

      body = conn |> get("/#{ctx.plural}/index.json?from=2020-01-01") |> json_response(200)

      {:ok, echoed, _} = DateTime.from_iso8601(body["from"])
      assert DateTime.compare(echoed, Index.anchor()) == :eq
      assert Enum.map(body["events"], & &1["title"]) == ["Soon"]
    end

    test "a malformed bound reads as absent rather than 500ing", %{conn: conn} = ctx do
      published!(ctx, "Soon", 2)

      for query <- ["from=not-a-date", "until[]=x", "from[a]=1", "page[]=2"] do
        body = conn |> get("/#{ctx.plural}/index.json?#{query}") |> json_response(200)
        assert Enum.map(body["events"], & &1["title"]) == ["Soon"]
      end
    end
  end

  describe "pagination" do
    test "pages, and carries the window into the next page's link", %{conn: conn} = ctx do
      # One more than a page, so there IS a second page.
      for n <- 1..(Index.page_size() + 1), do: published!(ctx, "Gig #{n}", n)

      until = Date.utc_today() |> Date.add(400) |> Date.to_iso8601()
      body = conn |> get("/#{ctx.plural}?until=#{until}") |> html_response(200)

      # The window must survive into page two, or "Later" pages through a
      # different, unfiltered listing while looking like the same one.
      assert body =~ "until=#{until}"
      assert body =~ "page=2"

      page_two = conn |> get("/#{ctx.plural}?until=#{until}&page=2") |> json_or_html()
      assert page_two =~ "Gig #{Index.page_size() + 1}"
    end

    test "the JSON index reports the page and whether there is another",
         %{conn: conn} = ctx do
      for n <- 1..(Index.page_size() + 1), do: published!(ctx, "Gig #{n}", n)

      first = conn |> get("/#{ctx.plural}/index.json") |> json_response(200)
      assert first["page"] == 1
      assert first["has_more"] == true
      assert length(first["events"]) == Index.page_size()

      second = conn |> get("/#{ctx.plural}/index.json?page=2") |> json_response(200)
      assert second["page"] == 2
      assert second["has_more"] == false
      assert length(second["events"]) == 1
    end
  end

  defp json_or_html(conn), do: html_response(conn, 200)
end
