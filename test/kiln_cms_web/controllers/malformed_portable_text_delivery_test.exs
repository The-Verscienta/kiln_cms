defmodule KilnCMSWeb.MalformedPortableTextDeliveryTest do
  @moduledoc """
  A published row whose rich text body is malformed Portable Text still
  delivers (#2768).

  The `:rich_text` type casts as a list of maps, so a body with `marks` as a
  string, `children` that are not a list of maps, or a `markDefs` entry that
  is not a map could be stored, and then every render raised: the page
  answered 500, firing failed, and the editor and search indexing went down
  with it. Each shape in `KilnCMS.MalformedPortableText` is planted raw, past
  the write cast, the way such a row sits at rest.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Blocks.PortableText.Shape
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.Firing.Engine
  alias KilnCMS.MalformedPortableText
  alias KilnCMS.Repo

  @password "password123456"

  defp admin do
    email = "pt-shape-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp published_page do
    Ash.Seed.seed!(Page, %{
      title: "Malformed delivery",
      slug: "pt-shape-#{System.unique_integer([:positive])}",
      state: :published,
      published_at: DateTime.utc_now()
    })
  end

  defp envelope(body) do
    %{
      "type" => "rich_text",
      "value" => %{
        "_type" => "rich_text",
        "id" => Ash.UUID.generate(),
        "body" => body,
        "_version" => 1
      }
    }
  end

  defp body(poison), do: [MalformedPortableText.neighbor(), poison]

  # Straight to the column, as a row stored before any write check sits at rest.
  defp plant(page, column, blocks) do
    {1, _} =
      Repo.update_all(
        from(p in "pages", where: p.id == type(^page.id, Ecto.UUID)),
        set: [{column, blocks}]
      )

    :ok
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp assert_kept(_html, nil), do: :ok
  defp assert_kept(html, kept), do: assert(html =~ kept)

  defp rich_text_json(artifacts) do
    Enum.find(artifacts.json["blocks"], &(&1["_type"] == "rich_text"))
  end

  # A top-level node that is not a map used to be refused on load, by the
  # `:rich_text` field's list-of-maps cast, before any renderer saw it; the
  # stored cast now repairs the body first (PR 2 of #2768).
  for {name, poison, kept} <- MalformedPortableText.shapes() do
    @poison poison
    @kept kept

    # Fails on the code before #2768 for every shape but the numeric-string
    # level, which the old HTML renderer already nested correctly. The
    # top-level binary node failed until the stored cast repaired it.
    test "the published page renders (#{name})", %{conn: conn} do
      page = published_page()
      :ok = plant(page, :blocks, [envelope(body(@poison))])

      html = html_response(get(conn, ~p"/#{page.slug}"), 200)

      assert html =~ "Neighbor stays"
      assert_kept(html, @kept)
    end

    # Fails on the code before #2768 for every shape: firing raised, or (for
    # the numeric-string level) the `:json` body went out as stored.
    test "firing succeeds and the :json body is repaired (#{name})" do
      page = published_page()
      :ok = plant(page, :blocks, [envelope(body(@poison))])

      assert {:ok, artifacts} = Engine.fire(reload(page))

      assert artifacts.web["html"] =~ "Neighbor stays"

      json_body = rich_text_json(artifacts)["body"]
      assert Shape.well_formed?(json_body)
      assert hd(json_body) == MalformedPortableText.neighbor()
    end
  end

  describe "the :json artifact carries the repaired body" do
    # Fails on the code before #2768: firing raised in the `:web` render.
    test "marks as a string become a one-item list" do
      page = published_page()
      poison = MalformedPortableText.block([MalformedPortableText.span("Bold", "strong")])
      :ok = plant(page, :blocks, [envelope(body(poison))])

      assert {:ok, artifacts} = Engine.fire(reload(page))

      assert rich_text_json(artifacts)["body"] == [
               MalformedPortableText.neighbor(),
               %{
                 "_type" => "block",
                 "_key" => "b0",
                 "style" => "normal",
                 "markDefs" => [],
                 "children" => [%{"_type" => "span", "text" => "Bold", "marks" => ["strong"]}]
               }
             ]
    end

    # Fails on the code before #2768: firing raised in the `:web` render.
    test "string children become one span" do
      page = published_page()
      poison = MalformedPortableText.block("Loose prose", %{"style" => "h2"})
      :ok = plant(page, :blocks, [envelope(body(poison))])

      assert {:ok, artifacts} = Engine.fire(reload(page))

      assert rich_text_json(artifacts)["body"] == [
               MalformedPortableText.neighbor(),
               %{
                 "_type" => "block",
                 "_key" => "b0",
                 "style" => "h2",
                 "markDefs" => [],
                 "children" => [%{"_type" => "span", "text" => "Loose prose", "marks" => []}]
               }
             ]

      assert artifacts.web["html"] =~ "Loose prose</h2>"
    end
  end

  describe "editing a poisoned record" do
    setup do
      page = published_page()
      shape = MalformedPortableText.block("String children")
      :ok = plant(page, :blocks, [envelope(body(shape))])
      %{page: page, admin: admin()}
    end

    # Fails on the code before #2768: hydrating the editor rendered the body.
    test "the editor mounts", %{conn: conn, page: page, admin: admin} do
      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ "Neighbor stays"
    end

    # Fails on the code before #2768: SetSearchText flattened the body and raised.
    test "saving the loaded blocks back recomputes search text", %{page: page, admin: admin} do
      loaded = reload(page)

      assert {:ok, saved} =
               CMS.update_page(loaded, %{title: "Echo save", blocks: loaded.blocks}, actor: admin)

      assert saved.search_text =~ "Neighbor stays"
      assert saved.search_text =~ "String children"
    end
  end

  # Fails on the code before #2768: promoting recomputes search text from the
  # working copy's body.
  test "promoting a poisoned working copy succeeds" do
    admin = admin()

    page =
      CMS.create_page!(
        %{
          title: "Promote",
          slug: "pt-shape-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "rich_text", "body" => [MalformedPortableText.neighbor()]}]
        },
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)

    {:ok, page} =
      CMS.save_page_working_copy(
        reload(page),
        %{working_title: "Promote", working_blocks: [%{"_type" => "rich_text", "body" => []}]},
        actor: admin,
        tenant: page.org_id
      )

    :ok =
      plant(page, :working_blocks, [
        envelope(body(MalformedPortableText.block(["Working copy words"])))
      ])

    assert {:ok, promoted} = CMS.publish_page_changes(reload(page), %{}, actor: admin)

    assert promoted.search_text =~ "Working copy words"
    assert PortableText.to_html(hd(reload(page).blocks).value.body) =~ "Working copy words"
  end

  # PR 2 of #2768: an internal writer rebuilds its input from what is stored,
  # so it repairs a stored body instead of refusing it the way a headless
  # `block_tree` write is refused.
  describe "internal writers holding a stored malformed body" do
    # Fails on the code before #2768: the record could not be loaded at all.
    test "a record whose body holds a top-level non-map node loads, repaired" do
      page = published_page()
      :ok = plant(page, :blocks, [envelope([MalformedPortableText.neighbor(), "x", 1, nil])])

      assert [%Ash.Union{value: %{body: [neighbor]}}] = reload(page).blocks
      assert neighbor == MalformedPortableText.neighbor()
    end

    # Fails on the code before #2768: a nested child's fields reached the
    # reader as stored. The `note` fixture block's `summary` is a plugin
    # `:rich_text` field, which no renderer of its own repairs.
    test "a plugin :rich_text field nested in columns loads repaired" do
      page = published_page()
      poison = MalformedPortableText.block([MalformedPortableText.span("Nested", "strong")])

      columns = %{
        "type" => "columns",
        "value" => %{
          "_type" => "columns",
          "id" => Ash.UUID.generate(),
          "_version" => 1,
          "columns" => [
            %{"blocks" => [%{"_type" => "note", "title" => "N", "summary" => ["x", poison]}]}
          ]
        }
      }

      :ok = plant(page, :blocks, [columns])

      assert [%Ash.Union{value: %{columns: [%{"blocks" => [note]}]}}] = reload(page).blocks
      assert [%{"children" => [%{"marks" => ["strong"]}]}] = note["summary"]
    end

    # Fails on the code before #2768: the stored body was written back as it
    # was (and, with a top-level non-map node, refused by the cast).
    test "promoting a working copy stores the repaired body" do
      admin = admin()

      page =
        CMS.create_page!(
          %{
            title: "Promote",
            slug: "pt-shape-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "rich_text", "body" => [MalformedPortableText.neighbor()]}]
          },
          actor: admin
        )

      page = CMS.publish_page!(page, %{}, actor: admin)

      {:ok, page} =
        CMS.save_page_working_copy(
          reload(page),
          %{working_title: "Promote", working_blocks: [%{"_type" => "rich_text", "body" => []}]},
          actor: admin,
          tenant: page.org_id
        )

      poison = MalformedPortableText.block([MalformedPortableText.span("Held", "strong")])
      :ok = plant(page, :working_blocks, [envelope(["x", poison])])

      assert {:ok, _promoted} = CMS.publish_page_changes(reload(page), %{}, actor: admin)

      assert [%{"children" => [%{"marks" => ["strong"]}]}] = stored_body(page)
    end

    # Fails on the code before #2768: the version's body was refused by the cast.
    test "restoring a version whose body holds a malformed node succeeds" do
      admin = admin()

      page =
        CMS.create_page!(
          %{
            title: "Restore",
            slug: "pt-shape-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "rich_text", "body" => [MalformedPortableText.neighbor()]}]
          },
          actor: admin
        )

      [version] =
        CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
        |> Enum.filter(&(&1.version_source_id == page.id))

      poison = MalformedPortableText.block([MalformedPortableText.span("Old", "strong")])
      blocks = [envelope([MalformedPortableText.neighbor(), "x", poison])]

      {1, _} =
        Repo.update_all(
          from(v in "pages_versions", where: v.id == type(^version.id, Ecto.UUID)),
          set: [changes: Map.put(version.changes, "blocks", blocks)]
        )

      {:ok, edited} = CMS.update_page(reload(page), %{title: "Edited"}, actor: admin)

      assert {:ok, _restored} =
               CMS.restore_page_version(edited, %{version_id: version.id}, actor: admin)

      assert [neighbor, %{"children" => [%{"marks" => ["strong"]}]}] = stored_body(page)
      assert neighbor == MalformedPortableText.neighbor()
    end

    # Fails on the code before #2768: the imported body was stored as sent.
    test "an envelope import stores the repaired body" do
      admin = admin()
      slug = "pt-shape-#{System.unique_integer([:positive])}"
      poison = MalformedPortableText.block([MalformedPortableText.span("Imported", "strong")])

      envelope = %{
        "records" => [
          %{
            "type" => "page",
            "title" => "Imported",
            "slug" => slug,
            "blocks" => [envelope(["x", poison])]
          }
        ]
      }

      {:ok, report} =
        KilnCMS.Portability.Import.run_envelope(envelope,
          actor: admin,
          skip_media: true
        )

      assert report.failed == []
      [%{id: id}] = report.created

      assert [%{"children" => [%{"marks" => ["strong"]}]}] = stored_body(%{id: id})
    end
  end

  # The body as it sits in the column, not as a read repairs it.
  defp stored_body(page) do
    [%{"value" => %{"body" => body}}] =
      Repo.one!(from(p in "pages", where: p.id == type(^page.id, Ecto.UUID), select: p.blocks))

    body
  end
end
