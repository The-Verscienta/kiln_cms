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

  # A top-level node that is not a map is left out: the stored `:rich_text`
  # value is refused on load, before any renderer sees it, so the read fails
  # whatever the renderers do. The renderer tests cover it.
  for {name, poison, kept} <- MalformedPortableText.shapes(), is_map(poison) do
    @poison poison
    @kept kept

    # Fails on the code before #2768 for every shape but the numeric-string level.
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
      assert rich_text_json(artifacts)["body"] == PortableText.repair_body(body(@poison))
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
end
