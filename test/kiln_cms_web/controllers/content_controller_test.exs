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
  end

  describe "/blog index" do
    test "lists published posts but not drafts", %{conn: conn} do
      post(%{title: "ShownPost"})
      post(%{title: "HiddenDraft", state: :draft, published_at: nil})

      html = conn |> get(~p"/blog") |> html_response(200)
      assert html =~ "ShownPost"
      refute html =~ "HiddenDraft"
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
end
