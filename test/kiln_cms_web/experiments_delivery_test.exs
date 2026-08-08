defmodule KilnCMSWeb.ExperimentsDeliveryTest do
  @moduledoc """
  Experiments on both delivery surfaces (#499), and the five invariants
  `KilnCMS.Experiments` promises.

  Each invariant has a test named after it. They are the load-bearing claims —
  a variant that reaches an index or a shared cache is not a bug in a feature,
  it is the feature silently doing the thing it exists not to do.
  """
  use KilnCMSWeb.ConnCase, async: false

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments

  @headline "Canonical headline"
  @variant_headline "Varied headline"

  setup do
    ExperimentFixtures.enable!()
    %{org_id: KilnCMS.Accounts.default_org_id(), actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "exp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "exp-#{System.unique_integer([:positive])}"

  defp published_page(actor, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(%{title: @headline, slug: slug()}, attrs),
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    Ash.reload!(page, authorize?: false, tenant: page.org_id)
  end

  defp experimented_page(ctx, patch \\ %{"fields" => %{"title" => @variant_headline}}) do
    page = published_page(ctx.actor)
    {experiment, control, treatment} = ExperimentFixtures.pinned!(page, "page", patch)
    %{page: page, experiment: experiment, control: control, treatment: treatment}
  end

  describe "the rendered site" do
    test "serves the variant's copy in the body", ctx do
      %{page: page} = experimented_page(ctx)

      body = ctx.conn |> get("/#{page.slug}") |> html_response(200)

      assert body =~ @variant_headline
    end

    test "serves the canonical document when no experiment is running", ctx do
      page = published_page(ctx.actor)

      body = ctx.conn |> get("/#{page.slug}") |> html_response(200)

      assert body =~ @headline
    end

    test "serves the canonical document when the deployment switch is off", ctx do
      %{page: page} = experimented_page(ctx)

      original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
      Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)

      body = ctx.conn |> get("/#{page.slug}") |> html_response(200)

      assert body =~ @headline
      refute body =~ @variant_headline
    end

    test "a concluded experiment stops serving variants", ctx do
      %{page: page, experiment: experiment} = experimented_page(ctx)

      {:ok, _concluded} =
        Experiments.conclude_experiment(experiment, nil, authorize?: false, tenant: ctx.org_id)

      body = ctx.conn |> get("/#{page.slug}") |> html_response(200)

      assert body =~ @headline
      refute body =~ @variant_headline
    end

    test "patches a block by id", ctx do
      page =
        published_page(ctx.actor, %{
          blocks: [%{"_type" => "heading", "text" => "Original CTA"}]
        })

      # The stored blocks are union members wrapping the typed struct.
      [%Ash.Union{value: block}] = page.blocks
      block_id = block.id

      ExperimentFixtures.pinned!(page, "page", %{
        "blocks" => %{block_id => %{"text" => "Varied CTA"}}
      })

      body = ctx.conn |> get("/#{page.slug}") |> html_response(200)

      assert body =~ "Varied CTA"
      refute body =~ "Original CTA"
    end
  end

  describe "invariant 3: a variant changes what a human reads, never what a machine indexes" do
    test "the page title, meta description and JSON-LD stay canonical", ctx do
      %{page: page} = experimented_page(ctx)

      body = ctx.conn |> get("/#{page.slug}") |> html_response(200)

      # The visible body varies…
      assert body =~ @variant_headline

      # …but everything a crawler reads does not. The tag carries attributes, so
      # match it loosely rather than on a bare `<title>`.
      [title] = Regex.run(~r{<title[^>]*>(.*?)</title>}s, body, capture: :all_but_first)
      assert title =~ @headline
      refute title =~ @variant_headline

      [og_title] =
        Regex.run(~r{<meta property="og:title" content="([^"]*)"}, body, capture: :all_but_first)

      assert og_title == @headline

      [json_ld] =
        Regex.run(~r{<script type="application/ld\+json">(.*?)</script>}s, body,
          capture: :all_but_first
        )

      assert json_ld =~ @headline
      refute json_ld =~ @variant_headline
    end
  end

  describe "invariant 4: a page serving a variant is never shared-cached" do
    test "an experimented page is private and no-store", ctx do
      %{page: page} = experimented_page(ctx)

      conn = get(ctx.conn, "/#{page.slug}")

      assert ["private, no-store"] = get_resp_header(conn, "cache-control")
      # No ETag either: a conditional request would revalidate against a body
      # that is not the same for everyone.
      assert [] = get_resp_header(conn, "etag")
    end

    test "an ordinary page keeps its shared cache", ctx do
      page = published_page(ctx.actor)

      conn = get(ctx.conn, "/#{page.slug}")

      assert ["public, max-age=60, stale-while-revalidate=300"] =
               get_resp_header(conn, "cache-control")
    end
  end

  describe "the headless surface" do
    test "the same variant_key always resolves to the same variant", ctx do
      %{page: page} = experimented_page(ctx)

      first =
        ctx.conn
        |> get("/api/content/page/#{page.slug}?variant_key=visitor-1")
        |> get_resp_header("x-kiln-variant")

      second =
        build_conn()
        |> get("/api/content/page/#{page.slug}?variant_key=visitor-1")
        |> get_resp_header("x-kiln-variant")

      assert first == second
      assert first != []
    end

    test "the patched artifact carries the variant's copy", ctx do
      %{page: page} = experimented_page(ctx)

      body =
        ctx.conn
        |> get("/api/content/page/#{page.slug}?variant_key=visitor-1")
        |> json_response(200)

      assert body["title"] == @variant_headline
    end

    # Headless keeps `public` caching where the HTML surface cannot, because the
    # key is a query PARAMETER — every distinct key is a distinct URL, so a
    # shared cache stores one entry per arm with no `Vary` needed. Advertising
    # `Vary: X-Kiln-Variant-Key` would name a header nothing reads and would
    # clobber any `Vary` set upstream.
    test "advertises the variant, and needs no Vary to do it", ctx do
      %{page: page} = experimented_page(ctx)

      conn = get(ctx.conn, "/api/content/page/#{page.slug}?variant_key=visitor-1")

      assert [_variant_id] = get_resp_header(conn, "x-kiln-variant")
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      assert [] = get_resp_header(conn, "vary")
    end

    # Two keys that land on different arms must not share an ETag, or a
    # conditional request 304s a caller into the arm it was not assigned.
    test "the ETag carries the variant, so a 304 cannot cross arms", ctx do
      page = published_page(ctx.actor)

      ExperimentFixtures.running!(page, "page", %{
        "fields" => %{"title" => @variant_headline}
      })

      etags =
        for key <- 1..40 do
          build_conn()
          |> get("/api/content/page/#{page.slug}?variant_key=k#{key}")
          |> get_resp_header("etag")
        end

      # A fair split, so both arms are drawn — and their ETags differ.
      assert etags |> Enum.uniq() |> length() == 2
    end

    # A caller who has not opted in gets the canonical document. Drawing an arm
    # at random under `public, max-age=300` would let a CDN cache whichever one
    # the first caller drew and serve it to everyone.
    test "no variant_key means no variant, and no Vary", ctx do
      %{page: page} = experimented_page(ctx)

      conn = get(ctx.conn, "/api/content/page/#{page.slug}")
      body = json_response(conn, 200)

      assert body["title"] == @headline
      assert [] = get_resp_header(conn, "x-kiln-variant")
      assert [] = get_resp_header(conn, "vary")
    end

    test "the json_ld surface is never patched", ctx do
      %{page: page} = experimented_page(ctx)

      body =
        ctx.conn
        |> get("/api/content/page/#{page.slug}?surface=json_ld&variant_key=visitor-1")
        |> json_response(200)

      encoded = Jason.encode!(body)
      assert encoded =~ @headline
      refute encoded =~ @variant_headline
    end
  end

  describe "invariant 1: a variant is never fired" do
    test "the stored :json artifact stays canonical after a variant is served", ctx do
      %{page: page} = experimented_page(ctx)

      for _ <- 1..3, do: build_conn() |> get("/api/content/page/#{page.slug}?variant_key=k")

      {:ok, artifact} = KilnCMS.Firing.Engine.read(ctx.org_id, :page, page.id, :json)

      assert artifact["title"] == @headline
    end
  end

  describe "invariant 2: a variant never writes the document" do
    test "the record, its blocks, its search text and its version chain are untouched", ctx do
      page =
        published_page(ctx.actor, %{blocks: [%{"_type" => "heading", "text" => "Original CTA"}]})

      [%Ash.Union{value: block}] = page.blocks

      ExperimentFixtures.pinned!(page, "page", %{
        "fields" => %{"title" => @variant_headline},
        "blocks" => %{block.id => %{"text" => "Varied CTA"}}
      })

      versions_before = version_count(page, ctx.org_id)

      for _ <- 1..3, do: build_conn() |> get("/#{page.slug}")

      reloaded = Ash.reload!(page, authorize?: false, tenant: ctx.org_id)

      assert reloaded.title == @headline
      assert reloaded.updated_at == page.updated_at
      assert version_count(page, ctx.org_id) == versions_before

      # The stored block tree, and the search text derived from it.
      [%Ash.Union{value: stored}] = reloaded.blocks
      assert stored.text == "Original CTA"
      refute reloaded.search_text =~ "Varied CTA"
    end
  end

  # The invariants claim a variant cannot reach an index. These assert it on the
  # surfaces that actually read published content for a non-visitor purpose.
  describe "invariant 1: a variant never reaches an index" do
    setup ctx do
      %{page: page} = experimented_page(ctx)

      # Serve it a few times, so any write-through would have happened.
      for _ <- 1..3, do: build_conn() |> get("/#{page.slug}")

      %{page: page}
    end

    test "not the sitemap", ctx do
      body = ctx.conn |> get("/sitemap.xml") |> response(200)

      assert body =~ ctx.page.slug
      refute body =~ @variant_headline
    end

    test "not a feed", ctx do
      body = ctx.conn |> get("/feed.xml") |> response(200)

      assert body =~ @headline
      refute body =~ @variant_headline
    end

    test "not llms.txt", ctx do
      body = ctx.conn |> get("/llms.txt") |> response(200)

      refute body =~ @variant_headline
    end

    test "not the fired :web artifact a feed reads", ctx do
      {:ok, artifact} = KilnCMS.Firing.Engine.read(ctx.org_id, :page, ctx.page.id, :web)

      refute Jason.encode!(artifact) =~ @variant_headline
    end

    test "and no extra artifact row is written", ctx do
      artifacts =
        KilnCMS.Firing.PublishedArtifact
        |> Ash.Query.filter(document_id == ^ctx.page.id)
        |> Ash.read!(authorize?: false, tenant: ctx.org_id)

      # One per surface, and not one more.
      assert length(artifacts) == length(KilnCMS.Firing.Surfaces.all())
      refute Enum.any?(artifacts, &(Jason.encode!(&1.body) =~ @variant_headline))
    end
  end

  describe "invariant 5: an experiment write never touches the content record" do
    test "creating and starting an experiment cuts no version", ctx do
      page = published_page(ctx.actor)
      before = version_count(page, ctx.org_id)

      ExperimentFixtures.running!(page, "page", %{"fields" => %{"title" => @variant_headline}})

      reloaded = Ash.reload!(page, authorize?: false, tenant: ctx.org_id)

      assert version_count(page, ctx.org_id) == before
      assert reloaded.updated_at == page.updated_at
      assert reloaded.title == @headline
    end
  end

  defp version_count(page, org_id) do
    KilnCMS.CMS.Page.Version
    |> Ash.Query.filter(version_source_id == ^page.id)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> length()
  end
end
