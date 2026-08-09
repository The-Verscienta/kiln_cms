defmodule KilnCMS.Experiments.StickyTest do
  @moduledoc """
  Optional sticky assignment (#984).

  The privacy properties are the point of this file. `docs/data-flows.md`
  promises no visitor cookie, and this feature is the one thing that can make
  that untrue — so "off unless asked for", "a bucket and not an id", and "a
  bounded lifetime" are each pinned rather than left to the implementation.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments.Assignment
  alias KilnCMS.Experiments.Sticky

  @headline "Canonical headline"
  @variant_headline "Varied headline"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sticky-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp put_experiments(overrides) do
    original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
    Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)
  end

  defp published_page(actor) do
    page =
      CMS.create_page!(
        %{title: @headline, slug: "sticky-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    Ash.reload!(page, authorize?: false, tenant: page.org_id)
  end

  describe "off by default" do
    test "no cookie is read and none is written" do
      # The literal promise in docs/data-flows.md. With the switch unset this
      # code must not run at all — not "run and choose not to store".
      refute Sticky.enabled?()

      conn = build_conn()
      assert {nil, ^conn} = Sticky.bucket(conn)
    end

    test "an experimented page sets no cookie", %{conn: conn} do
      ExperimentFixtures.enable!()
      actor = admin()
      page = published_page(actor)
      ExperimentFixtures.pinned!(page, "page", %{"fields" => %{"title" => @variant_headline}})

      conn = get(conn, "/#{page.slug}")

      assert html_response(conn, 200) =~ @variant_headline

      # Specifically ours — the endpoint's session cookie is set on every
      # response and has nothing to do with this feature.
      refute Map.has_key?(conn.resp_cookies, Sticky.cookie())
    end
  end

  describe "when the operator opts in" do
    setup do
      ExperimentFixtures.enable!()
      put_experiments(sticky: true)
      actor = admin()
      page = published_page(actor)

      {experiment, control, treatment} =
        ExperimentFixtures.running!(page, "page", %{"fields" => %{"title" => @variant_headline}})

      %{page: page, experiment: experiment, control: control, treatment: treatment}
    end

    test "the first request mints a bucket cookie", ctx do
      conn = get(build_conn(), "/#{ctx.page.slug}")

      cookie = Map.fetch!(conn.resp_cookies, Sticky.cookie())

      # A bucket, not an identifier: a small integer in a fixed range.
      assert {bucket, ""} = Integer.parse(cookie.value)
      assert bucket >= 0 and bucket < Sticky.buckets()

      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.max_age == Sticky.max_age_seconds()
      # `Path=/` and `Secure` are what the `__Host-` prefix rides on; a browser
      # discards a violating prefixed cookie silently.
      assert cookie.path == "/"
      assert cookie.secure == String.starts_with?(Sticky.cookie(), "__Host-")
    end

    test "buckets are actually drawn, not a constant", ctx do
      # Every other test here would pass with `mint/1` returning a literal 0 —
      # and a constant bucket is a 100/0 split reported as the configured one.
      values =
        for _ <- 1..40 do
          build_conn() |> get("/#{ctx.page.slug}") |> Map.fetch!(:resp_cookies)
        end
        |> Enum.map(&Map.fetch!(&1, Sticky.cookie()).value)
        |> Enum.uniq()

      assert length(values) > 1
    end

    test "the same bucket keeps the same arm across requests", ctx do
      # The whole point of the feature: without it a reload re-draws.
      first = get(build_conn(), "/#{ctx.page.slug}")
      bucket = first.resp_cookies[Sticky.cookie()].value
      arm = variant_shown(first)

      for _ <- 1..8 do
        html =
          build_conn()
          |> put_req_cookie(Sticky.cookie(), bucket)
          |> get("/#{ctx.page.slug}")
          |> html_response(200)

        assert shown(html) == arm, "a returning visitor saw a different arm"
      end
    end

    test "a returning visitor's cookie is not re-minted", ctx do
      conn =
        build_conn()
        |> put_req_cookie(Sticky.cookie(), "7")
        |> get("/#{ctx.page.slug}")

      # Re-setting it on every response would extend the lifetime indefinitely,
      # which is how a bounded cookie quietly becomes a permanent one.
      refute Map.has_key?(conn.resp_cookies, Sticky.cookie())
    end

    test "a junk cookie is replaced rather than trusted", ctx do
      # No `"7; DROP TABLE"` here: `;` is the cookie header's own separator, so
      # the transport truncates it to `"7"` — a perfectly valid bucket — long
      # before this code sees it. Asserting it gets replaced would be asserting
      # something false about the parser.
      for junk <- ["", "abc", "-1", "999999", "3.5", "100", "7x", "1e2"] do
        conn =
          build_conn()
          |> put_req_cookie(Sticky.cookie(), junk)
          |> get("/#{ctx.page.slug}")

        assert %{value: value} = conn.resp_cookies[Sticky.cookie()],
               "junk cookie #{inspect(junk)} was not replaced"

        assert {bucket, ""} = Integer.parse(value)
        assert bucket >= 0 and bucket < Sticky.buckets()
      end
    end

    test "the page is still private and no-store", ctx do
      # Stickiness changes WHICH arm a visitor sees, not that the body differs
      # between visitors — a shared cache would still hand one visitor's arm to
      # another.
      conn = get(build_conn(), "/#{ctx.page.slug}")

      assert ["private, no-store"] = get_resp_header(conn, "cache-control")
    end

    test "a page with no experiment on it sets no cookie", ctx do
      # The cookie is minted on the experiment path, so an ordinary page — which
      # is nearly every page — stays cookieless even with the switch on.
      plain = published_page(admin())
      _ = ctx

      conn = get(build_conn(), "/#{plain.slug}")

      refute Map.has_key?(conn.resp_cookies, Sticky.cookie())
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
    end
  end

  describe "bucket assignment is proportional, not hashed" do
    test "a 50/50 split lands within one bucket of even" do
      # The reason `choose_bucket/3` exists rather than reusing the keyed hash
      # branch: `phash2` over a 100-value space fixes which side of the line
      # each bucket falls on, so the arms sit permanently off-centre and it
      # reads as a real effect. Scaling is exact.
      variants = [
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000001", weight: 1},
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000002", weight: 1}
      ]

      counts =
        0..(Sticky.buckets() - 1)
        |> Enum.map(&Assignment.choose_bucket(variants, &1, Sticky.buckets()))
        |> Enum.frequencies_by(& &1.id)
        |> Map.values()

      assert Enum.max(counts) - Enum.min(counts) <= 1
    end

    test "a 3:1 split lands within one bucket of 75/25" do
      variants = [
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000001", weight: 3},
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000002", weight: 1}
      ]

      counts =
        0..(Sticky.buckets() - 1)
        |> Enum.map(&Assignment.choose_bucket(variants, &1, Sticky.buckets()))
        |> Enum.frequencies_by(& &1.id)

      [heavy, light] = counts |> Map.values() |> Enum.sort(:desc)

      assert_in_delta heavy, 75, 1
      assert_in_delta light, 25, 1
    end

    test "the same bucket always resolves to the same arm" do
      variants = [
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000001", weight: 1},
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000002", weight: 1}
      ]

      for bucket <- 0..(Sticky.buckets() - 1) do
        a = Assignment.choose_bucket(variants, bucket, Sticky.buckets())
        b = Assignment.choose_bucket(variants, bucket, Sticky.buckets())
        assert a.id == b.id
      end
    end

    test "weights summing to zero serve the canonical document" do
      variants = [
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000001", weight: 0}
      ]

      assert Assignment.choose_bucket(variants, 0, Sticky.buckets()) == nil
    end

    test "a lopsided split does not starve the light arm" do
      # The trap this mapping exists to avoid: scaling the BUCKET up into weight
      # space (`div(bucket * total, buckets)`) makes every one of the 100 values
      # land below 999, so the second arm here is served to nobody at all while
      # the results table shows it running.
      variants = [
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000001", weight: 999},
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000002", weight: 1}
      ]

      counts =
        0..(Sticky.buckets() - 1)
        |> Enum.map(&Assignment.choose_bucket(variants, &1, Sticky.buckets()))
        |> Enum.frequencies_by(& &1.id)

      assert map_size(counts) == 2
      assert counts["00000000-0000-0000-0000-000000000002"] == 1
    end

    test "anything that is not a bucket in range chooses nothing" do
      # Live, not defensive: `assign_sticky` checks `Sticky.enabled?()` and
      # `Sticky.bucket/1` checks it again, so an operator flipping the switch
      # between the two reads hands this a `nil` — and a FunctionClauseError on
      # a delivery request would 500 a page.
      variants = [
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000001", weight: 1},
        %KilnCMS.Experiments.Variant{id: "00000000-0000-0000-0000-000000000002", weight: 1}
      ]

      for bad <- [nil, -1, "7", 1.5] do
        assert Assignment.choose_bucket(variants, bad, Sticky.buckets()) == nil
      end

      assert Assignment.choose_bucket(variants, 0, 0) == nil
    end
  end

  describe "the content_view goal (#984)" do
    setup do
      ExperimentFixtures.enable!()
      put_experiments(sticky: true)
      actor = admin()
      landing = published_page(actor)
      target = published_page(actor)

      {experiment, control, treatment} =
        ExperimentFixtures.pinned!(
          landing,
          "page",
          %{"fields" => %{"title" => @variant_headline}},
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: target.id
        )

      %{
        landing: landing,
        target: target,
        experiment: experiment,
        control: control,
        treatment: treatment
      }
    end

    test "seeing the experiment records an exposure", ctx do
      conn = get(build_conn(), "/#{ctx.landing.slug}")

      assert html_response(conn, 200) =~ @variant_headline

      exposure = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())
      assert exposure.value == ctx.treatment.id
      assert exposure.http_only
      assert exposure.max_age == Sticky.max_age_seconds()
    end

    test "viewing the target after exposure converts, once", ctx do
      conn =
        build_conn()
        |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
        |> get("/#{ctx.target.slug}")

      assert html_response(conn, 200)
      assert conversions(ctx, ctx.treatment.id) == 1

      # The exposure is spent: deleted, not rewritten, so a reload cannot
      # convert the same visitor again.
      assert %{max_age: 0} = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())

      build_conn() |> get("/#{ctx.target.slug}") |> html_response(200)
      assert conversions(ctx, ctx.treatment.id) == 1
    end

    test "the goal page leaves the shared cache while the experiment runs", ctx do
      # Invariant 4 applied to a SECOND page. The conversion is counted at the
      # origin, so a CDN holding this page for max-age=60 swallows every
      # conversion after the first — the experiment would report a fraction of
      # the truth and read as "the treatment did nothing".
      conn = get(build_conn(), "/#{ctx.target.slug}")

      assert ["private, no-store"] = get_resp_header(conn, "cache-control")

      # And an unrelated page is untouched: this costs the goal document its
      # CDN, not the whole site.
      plain = get(build_conn(), "/#{published_page(admin()).slug}")
      assert ["public, max-age=" <> _] = get_resp_header(plain, "cache-control")
    end

    test "viewing the target without exposure converts nothing", ctx do
      # The reason a bucket alone is not enough: this visitor HAS a bucket and
      # would be in an arm, but never saw the experiment.
      build_conn()
      |> put_req_cookie(Sticky.cookie(), "7")
      |> get("/#{ctx.target.slug}")
      |> html_response(200)

      assert conversions(ctx, ctx.treatment.id) == 0
      assert conversions(ctx, ctx.control.id) == 0
    end

    test "an exposure converts only on its own goal document", ctx do
      other = published_page(admin())

      build_conn()
      |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
      |> get("/#{other.slug}")
      |> html_response(200)

      assert conversions(ctx, ctx.treatment.id) == 0
    end

    test "a matching id on the wrong content type converts nothing", ctx do
      # `goal_content_type` and `goal_document_id` are checked together: two
      # sites' worth of documents can share neither, but a dynamic type (D17)
      # and a compiled one can hold rows the other's uuid would otherwise be
      # compared against by id alone.
      actor = admin()
      other = published_page(actor)

      # `:start` now refuses a goal document that does not resolve (#1008
      # review), so the mismatched pair cannot be created through the write
      # layer any more — which is the point of that gate. Delivery's own
      # type-AND-id comparison still has to hold for a row that reached this
      # state some other way, so the experiment starts with a real post as its
      # goal and is then seeded onto the page's id.
      post =
        CMS.create_post!(
          %{title: "Goal", slug: "sticky-post-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      {experiment, _control, treatment} =
        ExperimentFixtures.pinned!(other, "page", %{"fields" => %{"title" => @variant_headline}},
          goal: :content_view,
          goal_content_type: "post",
          goal_document_id: post.id
        )

      Ash.Seed.update!(experiment, %{goal_document_id: ctx.target.id})
      KilnCMS.Cache.bust_experiments(KilnCMS.Accounts.default_org_id())

      build_conn()
      |> put_req_cookie(Sticky.exposure_cookie(), treatment.id)
      |> get("/#{ctx.target.slug}")
      |> html_response(200)

      assert conversions(ctx, treatment.id) == 0
    end

    test "converting one exposure leaves the visitor's others alone", ctx do
      stranger = Ash.UUID.generate()

      conn =
        build_conn()
        |> put_req_cookie(
          Sticky.exposure_cookie(),
          Enum.join([ctx.treatment.id, stranger], ".")
        )
        |> get("/#{ctx.target.slug}")

      assert conversions(ctx, ctx.treatment.id) == 1

      # Spending one exposure must not wipe the rest: the other is an arm of a
      # different experiment the visitor has not reached the goal of yet.
      assert %{value: value} = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())
      assert String.split(value, ".") == [stranger]
    end

    test "a cookie naming BOTH arms converts exactly one of them", ctx do
      build_conn()
      |> put_req_cookie(
        Sticky.exposure_cookie(),
        Enum.join([ctx.control.id, ctx.treatment.id], ".")
      )
      |> get("/#{ctx.target.slug}")
      |> html_response(200)

      # A hand-edited cookie must not convert an experiment twice, and which
      # arm wins must not depend on the row order Postgres returned.
      assert conversions(ctx, ctx.control.id) + conversions(ctx, ctx.treatment.id) == 1
    end

    test "a page that is one experiment's landing and another's goal keeps both", ctx do
      # The read-modify-write within one request: `assign_sticky` writes an
      # exposure for the experiment ON this page, then `record_content_view`
      # spends a different one FOR this page. The second write must see the
      # first, or the chained funnel silently reports 0.0% forever.
      {_chained, _control, chained_treatment} =
        ExperimentFixtures.pinned!(
          ctx.target,
          "page",
          %{"fields" => %{"title" => @variant_headline}},
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: published_page(admin()).id
        )

      conn =
        build_conn()
        |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
        |> get("/#{ctx.target.slug}")

      assert conversions(ctx, ctx.treatment.id) == 1

      assert %{value: value} = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())
      assert String.split(value, ".") == [chained_treatment.id]
    end

    test "impressions count exposed visitors, not page views", ctx do
      # The denominator has to mean the same thing as the numerator: a visitor
      # can convert a content-view goal once, so counting their tenth reload of
      # the landing page would make the arm that brings people back look worse.
      bucketed = get(build_conn(), "/#{ctx.landing.slug}")
      bucket = bucketed.resp_cookies[Sticky.cookie()].value
      exposure = bucketed.resp_cookies[Sticky.exposure_cookie()].value

      for _ <- 1..5 do
        build_conn()
        |> put_req_cookie(Sticky.cookie(), bucket)
        |> put_req_cookie(Sticky.exposure_cookie(), exposure)
        |> get("/#{ctx.landing.slug}")
        |> html_response(200)
      end

      assert impressions(ctx, ctx.treatment.id) == 1
    end

    test "a junk exposure cookie converts nothing", ctx do
      for junk <- ["not-a-uuid", "", String.duplicate("a,", 500)] do
        build_conn()
        |> put_req_cookie(Sticky.exposure_cookie(), junk)
        |> get("/#{ctx.target.slug}")
        |> html_response(200)
      end

      assert conversions(ctx, ctx.treatment.id) == 0
    end

    test "a form-submission experiment records no exposure at all", ctx do
      # Exposure is only written for the goal that needs it — every other goal
      # converts on the page that carried the variant.
      plain = published_page(admin())
      ExperimentFixtures.pinned!(plain, "page", %{"fields" => %{"title" => @variant_headline}})
      _ = ctx

      conn = get(build_conn(), "/#{plain.slug}")

      assert html_response(conn, 200) =~ @variant_headline
      refute Map.has_key?(conn.resp_cookies, Sticky.exposure_cookie())
    end

    test "turning sticky back off stops the experiment rather than half-running it", ctx do
      # `:start` refuses a content-view experiment while sticky is off, but an
      # operator can turn it off afterwards — data-flows.md actively invites
      # gating the config on a consent mechanism. Serving on regardless is the
      # worse half of the failure this goal was built to avoid: the arms split,
      # the landing page loses its cache, impressions pile up, and nothing can
      # ever convert. So it serves nothing at all.
      put_experiments(sticky: false)

      landing =
        build_conn()
        |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
        |> get("/#{ctx.landing.slug}")

      refute html_response(landing, 200) =~ @variant_headline
      assert ["public, max-age=" <> _] = get_resp_header(landing, "cache-control")
      assert impressions(ctx, ctx.treatment.id) == 0

      build_conn()
      |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
      |> get("/#{ctx.target.slug}")
      |> html_response(200)

      assert conversions(ctx, ctx.treatment.id) == 0
    end

    test "a headless caller is never served a content_view arm", ctx do
      # A `variant_key` says which arm a caller WOULD be in, never that they
      # fetched the experimented document — so a headless conversion cannot be
      # attributed. Serving anyway would book impressions on a denominator the
      # numerator can never reach, diluting a real on-site effect by an amount
      # nobody can see.
      assert KilnCMS.Experiments.Delivery.assign_keyed("page", ctx.landing, "caller-1") == nil
      assert impressions(ctx, ctx.treatment.id) == 0
    end
  end

  describe "the funnel_completion goal (#1010)" do
    setup do
      ExperimentFixtures.enable!()
      put_experiments(sticky: true)
      actor = admin()
      landing = published_page(actor)
      middle = published_page(actor)
      last = published_page(actor)

      funnel = ExperimentFixtures.funnel_ending_at(middle, last, landing.org_id)

      {experiment, control, treatment} =
        ExperimentFixtures.pinned!(
          landing,
          "page",
          %{"fields" => %{"title" => @variant_headline}},
          goal: :funnel_completion,
          goal_funnel_id: funnel.id
        )

      %{
        landing: landing,
        middle: middle,
        last: last,
        funnel: funnel,
        experiment: experiment,
        control: control,
        treatment: treatment
      }
    end

    test "converting means reaching the funnel's LAST step", ctx do
      conn =
        build_conn()
        |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
        |> get("/#{ctx.last.slug}")

      assert html_response(conn, 200)
      assert conversions(ctx, ctx.treatment.id) == 1

      # And the exposure is spent, so a reload cannot convert twice.
      assert %{max_age: 0} = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())
    end

    test "the landing page mints the exposure a funnel goal needs", ctx do
      # Every other test here injects the cookie by hand, so without this,
      # reverting `count_exposure`'s guard to `:content_view` only would leave
      # them all green while a funnel experiment never minted `_kiln_ab_x` at
      # all and could therefore never convert.
      conn = get(build_conn(), "/#{ctx.landing.slug}")

      assert html_response(conn, 200) =~ @variant_headline
      assert %{value: value} = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())
      assert value == ctx.treatment.id
    end

    test "a headless caller is never served a funnel_completion arm", ctx do
      # Same reason as `content_view`: a `variant_key` says which arm a caller
      # would be in, never that they fetched the experimented document, so
      # serving one books impressions on a denominator no conversion can reach.
      assert KilnCMS.Experiments.Delivery.assign_keyed("page", ctx.landing, "caller-1") == nil
      assert impressions(ctx, ctx.treatment.id) == 0
    end

    test "a funnel edited to end on the experimented document stops converting", ctx do
      # `:start` refuses this, but the feature's whole point is that editing the
      # funnel moves the goal — so an editor can reach the refused state
      # afterwards and nothing about a funnel write knows an experiment exists.
      # Unguarded, the impression converts itself within the same request and
      # every arm reports 100% forever.
      KilnCMS.Analytics.create_funnel_step!(
        %{
          funnel_id: ctx.funnel.id,
          content_type: "page",
          content_id: ctx.landing.id,
          position: 9
        },
        authorize?: false,
        tenant: ctx.landing.org_id
      )

      conn = get(build_conn(), "/#{ctx.landing.slug}")

      assert html_response(conn, 200) =~ @variant_headline
      assert conversions(ctx, ctx.treatment.id) == 0
    end

    test "an intermediate step does not convert", ctx do
      # The honest limit of this goal, asserted rather than left implied: Kiln
      # keeps no per-visitor journey, so "completed" means "reached the end",
      # not "walked every step in order".
      build_conn()
      |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
      |> get("/#{ctx.middle.slug}")
      |> html_response(200)

      assert conversions(ctx, ctx.treatment.id) == 0
    end

    test "the goal follows the funnel when its last step changes", ctx do
      # The reason this is not just `content_view` pointed at a document: the
      # experiment names a funnel, so re-ordering the funnel moves the goal
      # without anyone editing the experiment.
      newest = published_page(admin())

      KilnCMS.Analytics.create_funnel_step!(
        %{funnel_id: ctx.funnel.id, content_type: "page", content_id: newest.id, position: 9},
        authorize?: false,
        tenant: ctx.landing.org_id
      )

      build_conn()
      |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
      |> get("/#{ctx.last.slug}")
      |> html_response(200)

      assert conversions(ctx, ctx.treatment.id) == 0

      build_conn()
      |> put_req_cookie(Sticky.exposure_cookie(), ctx.treatment.id)
      |> get("/#{newest.slug}")
      |> html_response(200)

      assert conversions(ctx, ctx.treatment.id) == 1
    end

    test "the funnel's last step leaves the shared cache", ctx do
      # Same cost as `content_view`: the conversion is counted at the origin, so
      # a CDN holding that page swallows every conversion after the first.
      conn = get(build_conn(), "/#{ctx.last.slug}")

      assert ["private, no-store"] = get_resp_header(conn, "cache-control")

      # The middle step is untouched — this costs two pages their CDN, not the
      # whole funnel.
      plain = get(build_conn(), "/#{ctx.middle.slug}")
      assert ["public, max-age=" <> _] = get_resp_header(plain, "cache-control")
    end
  end

  describe "the exposure list itself" do
    setup do
      put_experiments(sticky: true)
      :ok
    end

    defp exposure_value(conn), do: conn.resp_cookies[Sticky.exposure_cookie()].value

    defp with_exposures(ids),
      do: put_req_cookie(build_conn(), Sticky.exposure_cookie(), Enum.join(ids, "."))

    test "caps at max_exposures, dropping the oldest" do
      ids = for _ <- 1..(Sticky.max_exposures() + 2), do: Ash.UUID.generate()

      conn =
        Enum.reduce(ids, build_conn(), fn id, conn ->
          {_written, conn} = Sticky.remember_exposure(conn, id)
          # Feed each response's cookie back in as the next request's, the way a
          # browser would — otherwise every call starts from an empty list and
          # the cap is never reached.
          put_req_cookie(build_conn(), Sticky.exposure_cookie(), exposure_value(conn))
        end)

      {:new, conn} = Sticky.remember_exposure(conn, Ash.UUID.generate())
      kept = String.split(exposure_value(conn), ".")

      assert length(kept) == Sticky.max_exposures()
      # Newest first, so it is the OLDEST that falls off the end.
      refute List.first(ids) in kept
    end

    test "re-seeing the same arm does not re-set the cookie" do
      id = Ash.UUID.generate()

      assert {:repeat, conn} = Sticky.remember_exposure(with_exposures([id]), id)

      # Rewriting it every view would roll the lifetime forward forever, and
      # `:repeat` is also what stops the caller booking a second impression.
      refute Map.has_key?(conn.resp_cookies, Sticky.exposure_cookie())
    end

    test "an unmatchable entry is dropped or normalised rather than carried" do
      good = Ash.UUID.generate()

      {kept, _conn} =
        build_conn()
        # `Ecto.UUID.cast/1` accepts an UPPERCASE uuid and normalises it, so the
        # value carried has to be the cast one — the raw string would pass
        # validation, match no variant ever, and occupy a slot for 30 days.
        |> put_req_cookie(
          Sticky.exposure_cookie(),
          "junk.#{good}.also-junk.#{String.upcase(good)}"
        )
        |> Sticky.exposures()

      assert kept == [good]
    end

    test "a full cookie of unmatchable entries cannot squat the cap" do
      junk = for _ <- 1..(Sticky.max_exposures() * 3), do: String.upcase(Ash.UUID.generate())

      {kept, _conn} =
        build_conn()
        |> put_req_cookie(Sticky.exposure_cookie(), Enum.join(junk, "."))
        |> Sticky.exposures()

      # Normalised, so they are real uuids — the cap is what bounds them, and
      # each is still spendable rather than permanently inert.
      assert length(kept) == Sticky.max_exposures()
      assert Enum.all?(kept, &(&1 == String.downcase(&1)))
    end

    test "reads nothing at all while sticky is off" do
      put_experiments(sticky: false)
      conn = with_exposures([Ash.UUID.generate()])

      assert {[], ^conn} = Sticky.exposures(conn)
    end

    test "an empty list deletes the cookie rather than blanking it" do
      conn = Sticky.put_exposures(build_conn(), [])

      # A blank value would still be a cookie the visitor keeps sending.
      assert %{max_age: 0} = Map.fetch!(conn.resp_cookies, Sticky.exposure_cookie())
    end
  end

  describe "starting a content_view experiment" do
    setup do
      ExperimentFixtures.enable!()
      actor = admin()
      %{actor: actor, landing: published_page(actor), target: published_page(actor)}
    end

    test "is refused while sticky assignment is off", ctx do
      # The failure this prevents is invisible: traffic splits, the page loses
      # its shared cache, and every arm reports 0.0% forever.
      refute Sticky.enabled?()

      assert {:error, error} = start_content_view(ctx, ctx.target.id)
      assert Exception.message(error) =~ "sticky"
    end

    test "is refused when the goal document is the experimented one", ctx do
      put_experiments(sticky: true)

      assert {:error, error} = start_content_view(ctx, ctx.landing.id)
      assert Exception.message(error) =~ "cannot be the experimented document"
    end

    test "is refused with no target at all", ctx do
      put_experiments(sticky: true)

      assert {:error, error} = start_content_view(ctx, nil)
      assert Exception.message(error) =~ "target document"
    end

    test "a funnel goal is refused with no funnel, an unknown funnel, or an empty one", ctx do
      put_experiments(sticky: true)
      org_id = ctx.landing.org_id

      assert {:error, e} = start_funnel(ctx, nil)
      assert Exception.message(e) =~ "needs a funnel"

      assert {:error, e} = start_funnel(ctx, Ash.UUID.generate())
      assert Exception.message(e) =~ "no funnel"

      empty =
        KilnCMS.Analytics.create_funnel!(
          %{name: "Empty", slug: "empty-#{System.unique_integer([:positive])}"},
          authorize?: false,
          tenant: org_id
        )

      assert {:error, e} = start_funnel(ctx, empty.id)
      assert Exception.message(e) =~ "no steps"
    end

    test "a funnel goal is refused when the funnel ends on the experimented document", ctx do
      put_experiments(sticky: true)
      funnel = ExperimentFixtures.funnel_ending_at(ctx.target, ctx.landing, ctx.landing.org_id)

      assert {:error, e} = start_funnel(ctx, funnel.id)
      assert Exception.message(e) =~ "last step is the experimented document"
    end

    test "a funnel goal is refused while sticky assignment is off", ctx do
      refute Sticky.enabled?()
      funnel = ExperimentFixtures.funnel_ending_at(ctx.landing, ctx.target, ctx.landing.org_id)

      assert {:error, e} = start_funnel(ctx, funnel.id)
      assert Exception.message(e) =~ "sticky"
    end

    test "is refused when the target type is not a content type on this site", ctx do
      # The plural-URL-segment typo. Nothing about the resulting experiment
      # looks wrong — it serves, it splits, it books impressions — it just
      # converts nothing, forever.
      put_experiments(sticky: true)

      assert {:error, error} = start_content_view(ctx, ctx.target.id, "pages")
      assert Exception.message(error) =~ "not a content type on this site"
    end
  end

  describe "lifetime" do
    test "defaults to 30 days and is configurable" do
      # Bounded on purpose. A year is the reflex default and would make this a
      # standing marker rather than the life of an experiment.
      put_experiments(sticky: true)
      assert Sticky.max_age_seconds() == 30 * 24 * 60 * 60

      put_experiments(sticky: true, sticky_max_age_days: 14)
      assert Sticky.max_age_seconds() == 14 * 24 * 60 * 60
    end

    test "a nonsense setting falls back rather than disabling stickiness" do
      # `max-age=0` reads as "expire now": every request would re-mint, every
      # request would re-draw the arm, and the deployment would be back to
      # stateless assignment while the operator believed otherwise.
      for bad <- [0, -5, "14", nil] do
        put_experiments(sticky: true, sticky_max_age_days: bad)
        assert Sticky.max_age_seconds() == 30 * 24 * 60 * 60
      end
    end
  end

  # Built by hand rather than through the fixture: these cases are about `:start`
  # refusing a configuration, so the experiment has to reach `:start` holding it.
  defp start_content_view(ctx, goal_document_id, goal_type \\ "page") do
    org_id = ctx.landing.org_id

    experiment =
      KilnCMS.Experiments.create_experiment!(
        %{
          name: "cv-#{System.unique_integer([:positive])}",
          content_type: "page",
          document_id: ctx.landing.id,
          goal: :content_view,
          goal_content_type: if(goal_document_id, do: goal_type),
          goal_document_id: goal_document_id
        },
        authorize?: false,
        tenant: org_id
      )

    ExperimentFixtures.variant!(experiment, "Control", %{}, org_id, control: true)
    ExperimentFixtures.variant!(experiment, "Treatment", %{}, org_id, [])

    KilnCMS.Experiments.start_experiment(experiment, authorize?: false, tenant: org_id)
  end

  defp impressions(ctx, variant_id), do: counter(ctx, variant_id, :impressions)
  defp conversions(ctx, variant_id), do: counter(ctx, variant_id, :conversions)

  defp start_funnel(ctx, funnel_id) do
    org_id = ctx.landing.org_id

    experiment =
      KilnCMS.Experiments.create_experiment!(
        %{
          name: "fc-#{System.unique_integer([:positive])}",
          content_type: "page",
          document_id: ctx.landing.id,
          goal: :funnel_completion,
          goal_funnel_id: funnel_id
        },
        authorize?: false,
        tenant: org_id
      )

    ExperimentFixtures.variant!(experiment, "Control", %{}, org_id, control: true)
    ExperimentFixtures.variant!(experiment, "Treatment", %{}, org_id, [])

    KilnCMS.Experiments.start_experiment(experiment, authorize?: false, tenant: org_id)
  end

  defp counter(ctx, variant_id, field) do
    KilnCMS.Experiments.VariantDay
    |> Ash.read!(authorize?: false, tenant: ctx.landing.org_id)
    |> Enum.filter(&(&1.variant_id == variant_id))
    |> Enum.map(&Map.fetch!(&1, field))
    |> Enum.sum()
  end

  defp variant_shown(conn), do: conn |> html_response(200) |> shown()

  defp shown(html), do: if(html =~ @variant_headline, do: :treatment, else: :control)
end
