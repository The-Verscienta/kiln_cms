defmodule KilnCMS.Firing.LlmMarkdownTest do
  @moduledoc "The :llm fired surface (#357): clean chunked Markdown for answer engines."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "llm-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "publishing fires a Markdown :llm artifact with real headings" do
    actor = admin()

    page =
      CMS.create_page!(
        %{
          title: "Herbal Basics",
          slug: "llm-#{System.unique_integer([:positive])}",
          blocks: [
            %{type: :heading, content: "Getting started", data: %{"level" => 2}, order: 0},
            %{
              type: :rich_text,
              content: "<p>Steep the <strong>leaves</strong> gently.</p>",
              order: 1
            }
          ]
        },
        actor: actor
      )

    page = CMS.publish_page!(page, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()

    assert {:ok, %{"markdown" => md}} = Engine.read(page.org_id, :page, page.id, :llm)
    assert md =~ "# Herbal Basics"
    assert md =~ "## Getting started"
    # Rich text contributes its plain-text projection, not HTML.
    assert md =~ "Steep the leaves gently."
    refute md =~ "<p>"
    # Blocks separate with blank lines — naturally chunkable passages.
    assert md =~ "## Getting started\n\n"
  end

  test "the delivery route serves the :llm surface as raw text/markdown" do
    actor = admin()

    page =
      CMS.create_page!(
        %{title: "Served MD", slug: "llm-d-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/page/#{page.slug}", %{
        "surface" => "llm"
      })

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "text/markdown"
    assert conn.resp_body =~ "# Served MD"
  end

  test "a columns layout keeps per-block structure in the markdown" do
    # Composer-level: a columns container recurses its children through the
    # shared to_markdown dispatch instead of flattening to one line.
    columns = %KilnCMS.Blocks.Columns{
      layout: "1-1",
      gap: "md",
      columns: [
        %{
          "blocks" => [
            %{"_type" => "heading", "text" => "Left head", "level" => 3},
            %{"_type" => "quote", "text" => "Left body", "citation" => nil}
          ]
        },
        %{"blocks" => [%{"_type" => "quote", "text" => "Right body", "citation" => nil}]}
      ]
    }

    md = KilnCMS.Firing.LlmMarkdown.compose(%{title: "Layout MD"}, [columns])

    assert md =~ "### Left head"
    assert md =~ "Left body\n\nRight body"
  end

  test "the point-in-time route serves surface=llm as raw markdown too" do
    actor = admin()

    page =
      CMS.create_page!(
        %{title: "PIT MD", slug: "llm-p-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()

    as_of = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(
        KilnCMSWeb.Endpoint,
        :get,
        "/api/content/page/#{page.slug}",
        %{"surface" => "llm", "as_of" => as_of}
      )

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "text/markdown"
    assert conn.resp_body =~ "# PIT MD"
  end

  test "llms.txt links each entry's Markdown form" do
    actor = admin()

    page =
      CMS.create_page!(
        %{title: "Indexed MD", slug: "llm-i-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    # llms.txt is cached per org — bust so this test sees the fresh publish.
    KilnCMS.Cache.bust_llms(page.org_id)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/llms.txt")

    assert conn.resp_body =~ "Indexed MD"
    assert conn.resp_body =~ "/api/content/page/#{page.slug}?surface=llm"
  end
end
