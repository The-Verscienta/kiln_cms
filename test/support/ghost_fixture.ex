defmodule KilnCMS.GhostFixture do
  @moduledoc """
  A Ghost JSON export in the shape a real one has (#1876): `db[0].data` table
  dumps joined by id, SEO in `posts_meta`, `__GHOST_URL__` in stored URLs, an
  internal `#` tag, a members-only post, a scheduled post, an email-only post
  and a page.
  """

  @doc "A small but structurally faithful Ghost export, as a JSON string."
  @spec json(keyword()) :: String.t()
  def json(opts \\ []) do
    opts |> export() |> Jason.encode!()
  end

  @doc "The decoded export, for tests that reshape it."
  @spec export(keyword()) :: map()
  def export(opts \\ []) do
    posts = Keyword.get(opts, :posts, posts())

    %{
      "db" => [
        %{
          "meta" => %{"exported_on" => 1_759_000_000_000, "version" => "6.68.0"},
          "data" => %{
            "posts" => posts,
            "posts_meta" => [
              %{
                "post_id" => "p1",
                "meta_title" => "Hello, SEO",
                "meta_description" => "The search snippet.",
                "feature_image_alt" => "A kiln at dusk",
                "email_only" => false
              },
              %{"post_id" => "p5", "email_only" => true}
            ],
            "tags" => [
              %{"id" => "t1", "name" => "News", "slug" => "news", "visibility" => "public"},
              %{"id" => "t2", "name" => "How To", "slug" => "how-to", "visibility" => "public"},
              %{
                "id" => "t3",
                "name" => "#hide-cover",
                "slug" => "hash-hide-cover",
                "visibility" => "internal"
              }
            ],
            "posts_tags" => [
              %{"id" => "pt2", "post_id" => "p1", "tag_id" => "t2", "sort_order" => 1},
              %{"id" => "pt1", "post_id" => "p1", "tag_id" => "t1", "sort_order" => 0},
              %{"id" => "pt3", "post_id" => "p1", "tag_id" => "t3", "sort_order" => 2}
            ],
            "users" => [
              %{
                "id" => "u1",
                "name" => "Jo Example",
                "slug" => "jo",
                "email" => "jo@old.example.com"
              }
            ],
            "posts_authors" => [
              %{"id" => "pa1", "post_id" => "p1", "author_id" => "u1", "sort_order" => 0}
            ],
            "settings" => [%{"key" => "title", "value" => "Old Ghost Blog"}]
          }
        }
      ]
    }
  end

  @doc "The fixture's posts table."
  @spec posts() :: [map()]
  def posts do
    [
      post("p1", "hello-world", "Hello world",
        html:
          ~s(<p>First paragraph with <strong>bold</strong>.</p>) <>
            ~s(<figure class="kg-card kg-image-card"><img src="__GHOST_URL__/content/images/2026/01/pic.jpg" alt="Pic"></figure>) <>
            ~s(<p>[not a shortcode]</p>),
        feature_image: "__GHOST_URL__/content/images/2026/01/cover.jpg",
        custom_excerpt: "A short summary.",
        published_at: "2026-01-15T09:30:00.000Z"
      ),
      post("p2", "members-only", "Members only", visibility: "members"),
      post("p3", "coming-soon", "Coming soon",
        status: "scheduled",
        published_at: "2027-01-01T00:00:00.000Z"
      ),
      post("p4", "about", "About", type: "page"),
      post("p5", "weekly-letter", "Weekly letter"),
      post("p6", "a-draft", "A draft", status: "draft", published_at: nil)
    ]
  end

  @doc "One `posts` row with Ghost's columns; `opts` override them."
  @spec post(String.t(), String.t(), String.t(), keyword()) :: map()
  def post(id, slug, title, opts \\ []) do
    Map.merge(
      %{
        "id" => id,
        "uuid" => "uuid-" <> id,
        "title" => title,
        "slug" => slug,
        "mobiledoc" => nil,
        "lexical" => ~s({"root":{}}),
        "html" => "<p>#{title} body.</p>",
        "plaintext" => "#{title} body.",
        "feature_image" => nil,
        "featured" => false,
        "type" => "post",
        "status" => "published",
        "locale" => nil,
        "visibility" => "public",
        "created_at" => "2026-01-01T00:00:00.000Z",
        "updated_at" => "2026-01-02T00:00:00.000Z",
        "published_at" => "2026-01-02T00:00:00.000Z",
        "custom_excerpt" => nil,
        "codeinjection_head" => nil,
        "canonical_url" => nil
      },
      Map.new(opts, fn {key, value} -> {to_string(key), value} end)
    )
  end
end
