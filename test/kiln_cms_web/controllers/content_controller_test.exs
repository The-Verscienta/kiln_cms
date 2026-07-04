defmodule KilnCMSWeb.ContentControllerTest do
  @moduledoc """
  Public delivery only exposes published content: pages at `/<slug>`, posts at
  `/blog/<slug>`, and a `/blog` index. Drafts and unknown slugs 404.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  defp uniq, do: System.unique_integer([:positive])

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "pg-#{uniq()}", state: :published}, attrs)
    )
  end

  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(
        %{
          title: "A post",
          slug: "po-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  describe "pages" do
    test "renders a published page with its blocks at /:slug", %{conn: conn} do
      page =
        page(%{
          title: "Public Page",
          blocks: [%{type: :heading, content: "Hello Heading", order: 0}]
        })

      conn = get(conn, ~p"/#{page.slug}")

      assert html = html_response(conn, 200)
      assert html =~ "Public Page"
      assert html =~ "Hello Heading"
    end

    test "image blocks render a responsive srcset + alt from the media library", %{conn: conn} do
      media =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "p.jpg",
          url: "/uploads/orig",
          content_type: "image/jpeg",
          width: 1600,
          height: 1067,
          alt: "A described image",
          variants: %{
            "thumb" => %{"key" => "t", "url" => "/uploads/thumb", "width" => 400, "height" => 267},
            "medium" => %{
              "key" => "m",
              "url" => "/uploads/medium",
              "width" => 1024,
              "height" => 683
            }
          }
        })

      page =
        page(%{
          title: "Img Page",
          blocks: [
            %{type: :image, content: "/uploads/orig", data: %{"media_id" => media.id}, order: 0}
          ]
        })

      html = conn |> get(~p"/#{page.slug}") |> html_response(200)

      assert html =~ "/uploads/thumb 400w"
      assert html =~ "/uploads/medium 1024w"
      assert html =~ "/uploads/orig 1600w"
      assert html =~ ~s(alt="A described image")
      assert html =~ ~s(width="1600")
    end

    test "focal point flows to object-position; cropped variants stay out of srcset", %{
      conn: conn
    } do
      media =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "f.jpg",
          url: "/uploads/f-orig",
          content_type: "image/jpeg",
          width: 1600,
          height: 1067,
          focal_x: 0.2,
          focal_y: 0.8,
          variants: %{
            "thumb" => %{
              "key" => "t",
              "url" => "/uploads/f-thumb",
              "width" => 400,
              "height" => 267
            },
            # A focal-aware crop: different aspect — must NOT enter the srcset.
            "card" => %{"key" => "c", "url" => "/uploads/f-card", "width" => 800, "height" => 450}
          }
        })

      page =
        page(%{
          title: "Focal Page",
          blocks: [
            %{type: :image, content: "/uploads/f-orig", data: %{"media_id" => media.id}, order: 0}
          ]
        })

      html = conn |> get(~p"/#{page.slug}") |> html_response(200)

      assert html =~ ~s(style="object-position: 20% 80%")
      assert html =~ "/uploads/f-thumb 400w"
      refute html =~ "/uploads/f-card"
    end

    test "sets SEO metadata in the document head", %{conn: conn} do
      page = page(%{seo_title: "Meta Title", seo_description: "A great page."})

      html = conn |> get(~p"/#{page.slug}") |> html_response(200)

      assert html =~ "Meta Title · KilnCMS</title>"
      assert html =~ ~s(name="description" content="A great page.")
      assert html =~ ~s(property="og:title" content="Meta Title")
    end

    test "404s for a draft page's slug", %{conn: conn} do
      page = page(%{state: :draft})
      assert conn |> get(~p"/#{page.slug}") |> response(404)
    end

    test "404s for an unknown slug", %{conn: conn} do
      assert conn |> get(~p"/no-such-page") |> response(404)
    end
  end

  describe "posts" do
    test "renders a published post at /blog/:slug", %{conn: conn} do
      post =
        post(%{
          title: "Public Post",
          excerpt: "A lead-in.",
          blocks: [%{type: :heading, content: "Post Heading", order: 0}]
        })

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)
      assert html =~ "Public Post"
      assert html =~ "A lead-in."
      assert html =~ "Post Heading"
    end

    test "404s for a draft post's slug", %{conn: conn} do
      post = post(%{state: :draft, published_at: nil})
      assert conn |> get(~p"/blog/#{post.slug}") |> response(404)
    end

    test "emits BlogPosting JSON-LD in the head", %{conn: conn} do
      post = post(%{title: "Structured Post"})

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ ~s(<script type="application/ld+json">)
      assert html =~ ~s("@type":"BlogPosting")
      assert html =~ ~s("headline":"Structured Post")
      # URL is present (slashes are \/-escaped by escape: :html_safe).
      assert html =~ post.slug
    end

    test "emits a Person author and a BreadcrumbList for an authored post", %{conn: conn} do
      author =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "byline-#{uniq()}@example.com",
          hashed_password: "x",
          name: "Jane Doe"
        })

      post = post(%{title: "Bylined", author_id: author.id})

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ ~s("@type":"Person")
      assert html =~ ~s("name":"Jane Doe")
      assert html =~ ~s("@type":"BreadcrumbList")
    end
  end

  describe "/blog index" do
    test "lists published posts but not drafts", %{conn: conn} do
      post(%{title: "ShownPost"})
      post(%{title: "HiddenDraft", state: :draft, published_at: nil})

      html = conn |> get(~p"/blog") |> html_response(200)
      assert html =~ "ShownPost"
      refute html =~ "HiddenDraft"
    end

    test "emits CollectionPage JSON-LD", %{conn: conn} do
      post(%{title: "Indexed"})

      html = conn |> get(~p"/blog") |> html_response(200)
      assert html =~ ~s("@type":"CollectionPage")
      assert html =~ ~s("@type":"ItemList")
    end
  end

  describe "generic /:type/:slug delivery" do
    test "an unknown content type 404s", %{conn: conn} do
      # `widgets` is not a registered content type's path segment. (The happy
      # path — a generated type served at /<plural>/<slug> — is covered by the
      # ContentTypes registry tests and verified end-to-end.)
      assert conn |> get("/widgets/anything") |> response(404)
    end
  end

  describe "search page" do
    test "shows category facet counts and filters by ?category=<slug>", %{conn: conn} do
      term = "harvest#{uniq()}"

      category =
        Ash.Seed.seed!(KilnCMS.CMS.Category, %{name: "Recipes #{uniq()}", slug: "cat-#{uniq()}"})

      _inside = page(%{title: "#{term} inside", category_id: category.id})
      _outside = page(%{title: "#{term} outside"})

      html = conn |> get(~p"/search?q=#{term}") |> html_response(200)
      assert html =~ "#{term} inside"
      assert html =~ "#{term} outside"
      assert html =~ "(1)"
      assert html =~ category.name

      filtered =
        conn |> get(~p"/search?q=#{term}&category=#{category.slug}") |> html_response(200)

      assert filtered =~ "#{term} inside"
      refute filtered =~ "#{term} outside"
      # The clear-filter link appears once a facet is active.
      assert filtered =~ "All results"
    end

    test "a typo gets fuzzy-rescued results plus a did-you-mean link", %{conn: conn} do
      page = page(%{title: "Fermentation Handbook #{uniq()}"})

      html = conn |> get(~p"/search?q=fermentaton") |> html_response(200)

      assert html =~ page.title
      assert html =~ "Did you mean"
    end
  end
end
