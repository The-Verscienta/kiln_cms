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
