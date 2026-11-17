defmodule KilnCMSWeb.FlexibleMediaReferenceEditorTest do
  @moduledoc """
  The media and reference sub-fields of a flexible item in the content editor
  (#2282, PR 3, ADR 0065): the pickers inside an item card, at any depth, whose
  events carry the item's `_id` address and the sub-field name and nothing
  else. The server resolves both against the live form at event time, so a
  forged address, a sub-field of the wrong type, an item that has moved or
  gone, and a field the editor's write grant leaves out each change nothing.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  @hero "11111111-1111-4111-8111-111111111111"
  @hero2 "22222222-2222-4222-8222-222222222222"
  @columns "33333333-3333-4333-8333-333333333333"
  @cell "44444444-4444-4444-8444-444444444444"

  defp authed_user(role, extra \\ %{}) do
    email = "fmre-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )

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

  defp signed_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.put_new(attrs, :label, "Field"), actor: admin)

  defp item_type!(admin, flexible, name),
    do: def!(admin, %{name: name, field_type: :group, flex_of_id: flexible.id})

  defp sub!(admin, parent, name, attrs \\ %{}),
    do: def!(admin, Map.merge(%{name: name, group_of_id: parent.id, field_type: :string}, attrs))

  defp media!(name) do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "#{name}-#{System.unique_integer([:positive])}.png",
      url: "/uploads/#{name}-#{System.unique_integer([:positive])}.png",
      alt: "Alt #{name}",
      content_type: "image/png"
    })
  end

  setup %{conn: conn} do
    admin = authed_user(:admin)

    sections =
      def!(admin, %{
        content_type: :page,
        name: "sections",
        label: "Sections",
        field_type: :flexible
      })

    hero = item_type!(admin, sections, "hero")
    sub!(admin, hero, "headline")
    sub!(admin, hero, "image", %{field_type: :media, position: 1})

    sub!(admin, hero, "link", %{
      field_type: :reference,
      target_type: "page",
      position: 2
    })

    columns = item_type!(admin, sections, "columns")
    cells = sub!(admin, columns, "cells", %{field_type: :flexible})
    cell = item_type!(admin, cells, "cell")
    sub!(admin, cell, "label")
    sub!(admin, cell, "photo", %{field_type: :media, position: 1})

    target =
      CMS.create_page!(%{title: "Target page", slug: "t-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    target = CMS.publish_page!(target, %{}, actor: admin)

    picture = media!("one")
    other_picture = media!("two")

    page =
      CMS.create_page!(
        %{
          title: "Flexible media",
          slug: "fmre-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "sections" => [
              %{"_id" => @hero, "_type" => "hero", "headline" => "One"},
              %{"_id" => @hero2, "_type" => "hero", "headline" => "Two"},
              %{
                "_id" => @columns,
                "_type" => "columns",
                "cells" => [%{"_id" => @cell, "_type" => "cell", "label" => "left"}]
              }
            ]
          }
        },
        actor: admin
      )

    {:ok, lv, _html} = conn |> signed_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    %{
      admin: admin,
      page: page,
      lv: lv,
      conn: conn,
      target: target,
      picture: picture,
      other_picture: other_picture
    }
  end

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields["sections"]
  defp item(ctx, id), do: Enum.find(stored(ctx), &(&1["_id"] == id))
  defp save(lv), do: lv |> form("#page-editor") |> render_submit()

  defp media_input(lv, id, sub),
    do:
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#cf-media-sections-#{id}-#{sub} input[type=hidden]")
      |> LazyHTML.attribute("value")

  defp ref_input(lv, id, sub),
    do:
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#custom-field-sections-#{id}-#{sub} > input[type=hidden]")
      |> LazyHTML.attribute("value")

  defp open_media(lv, at, sub),
    do: render_hook(lv, "open_item_media_picker", %{"at" => at, "field" => sub})

  defp pick_media(lv, at, sub, id),
    do:
      render_hook(lv, "pick_image", %{
        "index" => "item_media",
        "at" => at,
        "field" => sub,
        "id" => id
      })

  describe "a media sub-field" do
    test "renders one picker per item, each under an id of its own", ctx do
      assert has_element?(ctx.lv, "#cf-media-sections-#{@hero}-image-choose")
      assert has_element?(ctx.lv, "#cf-media-sections-#{@hero2}-image-choose")
      assert has_element?(ctx.lv, "#cf-media-sections-#{@columns}-cells-#{@cell}-photo-choose")
      assert render(ctx.lv) =~ "None selected"
    end

    test "picks through the drawer, saves a snapshot, and shows it after a reload", ctx do
      ctx.lv |> element("#cf-media-sections-#{@hero}-image-choose") |> render_click()

      ctx.lv
      |> element("button[phx-click=pick_image][phx-value-id='#{ctx.picture.id}']")
      |> render_click()

      assert media_input(ctx.lv, @hero, "image") == [ctx.picture.id]
      # The other item's picker is untouched.
      assert media_input(ctx.lv, @hero2, "image") == [""]

      save(ctx.lv)

      assert %{"image" => %{"id" => id, "url" => url}} = item(ctx, @hero)
      assert id == ctx.picture.id
      assert url == ctx.picture.url
      refute Map.has_key?(item(ctx, @hero2), "image")

      {:ok, lv, html} =
        ctx.conn
        |> recycle()
        |> signed_in(ctx.admin)
        |> live(~p"/editor/content/page/#{ctx.page.id}")

      assert html =~ ctx.picture.url
      assert media_input(lv, @hero, "image") == [ctx.picture.id]
      assert has_element?(lv, "#cf-media-sections-#{@hero}-image-remove")
    end

    test "opening the drawer for a real sub-field shows it", ctx do
      open_media(ctx.lv, "sections/#{@hero}", "image")
      assert has_element?(ctx.lv, "#image-picker-dialog")
    end

    test "replaces and clears", ctx do
      open_media(ctx.lv, "sections/#{@hero}", "image")
      pick_media(ctx.lv, "sections/#{@hero}", "image", ctx.picture.id)
      open_media(ctx.lv, "sections/#{@hero}", "image")
      pick_media(ctx.lv, "sections/#{@hero}", "image", ctx.other_picture.id)
      assert media_input(ctx.lv, @hero, "image") == [ctx.other_picture.id]

      ctx.lv |> element("#cf-media-sections-#{@hero}-image-remove") |> render_click()
      assert media_input(ctx.lv, @hero, "image") == [""]

      save(ctx.lv)
      refute match?(%{"image" => %{"id" => _}}, item(ctx, @hero))
    end

    test "works in a nested list, addressed by the id chain", ctx do
      at = "sections/#{@columns}/cells/#{@cell}"
      open_media(ctx.lv, at, "photo")
      pick_media(ctx.lv, at, "photo", ctx.picture.id)
      save(ctx.lv)

      assert [%{"photo" => %{"id" => id}}] = item(ctx, @columns)["cells"]
      assert id == ctx.picture.id
    end

    test "a pick lands on the item the drawer was opened for, after a reorder", ctx do
      open_media(ctx.lv, "sections/#{@hero}", "image")

      render_hook(ctx.lv, "flex_reorder", %{
        "field" => "sections",
        "order" => [@columns, @hero2, @hero]
      })

      pick_media(ctx.lv, "sections/#{@hero}", "image", ctx.picture.id)
      save(ctx.lv)

      assert %{"image" => %{"id" => id}} = item(ctx, @hero)
      assert id == ctx.picture.id
      refute Map.has_key?(item(ctx, @hero2), "image")
    end

    test "a forged or stale address, sub-field or type opens and writes nothing", ctx do
      gone = Ecto.UUID.generate()

      for {at, sub} <- [
            {"sections/#{gone}", "image"},
            {"sections/#{@hero}", "headline"},
            {"sections/#{@hero}", "link"},
            {"sections/#{@hero}", "nope"},
            {"sections/#{@hero}/cells/#{@cell}", "photo"},
            {"sections/#{@columns}", "photo"},
            {"sections", "image"},
            {"nope/#{@hero}", "image"},
            {"sections/#{@hero}/", "image"},
            {"", ""}
          ] do
        open_media(ctx.lv, at, sub)
        refute has_element?(ctx.lv, "#image-picker-dialog")
        pick_media(ctx.lv, at, sub, ctx.picture.id)
      end

      save(ctx.lv)
      refute Map.has_key?(item(ctx, @hero), "image")
      refute Map.has_key?(item(ctx, @hero), "link")
    end

    test "a pick for a drawer that is not open, or another one, changes nothing", ctx do
      pick_media(ctx.lv, "sections/#{@hero}", "image", ctx.picture.id)
      open_media(ctx.lv, "sections/#{@hero2}", "image")
      pick_media(ctx.lv, "sections/#{@hero}", "image", ctx.picture.id)

      assert media_input(ctx.lv, @hero, "image") == [""]
      assert media_input(ctx.lv, @hero2, "image") == [""]
    end

    test "a media id the editor cannot resolve is refused at the item's path on save", ctx do
      open_media(ctx.lv, "sections/#{@hero}", "image")
      pick_media(ctx.lv, "sections/#{@hero}", "image", Ecto.UUID.generate())
      html = save(ctx.lv)

      assert html =~ "sections[0].image" or html =~ "Image"
      refute Map.has_key?(item(ctx, @hero), "image")
    end

    test "malformed payloads are ignored", ctx do
      for params <- [%{}, %{"at" => 1, "field" => "image"}, %{"at" => "sections/#{@hero}"}] do
        render_hook(ctx.lv, "open_item_media_picker", params)
        render_hook(ctx.lv, "clear_item_media", params)
        render_hook(ctx.lv, "pick_image", Map.put(params, "index", "item_media"))
      end

      assert Process.alive?(ctx.lv.pid)
    end
  end

  describe "a reference sub-field" do
    defp search_id(id, sub), do: "#custom-field-sections-#{id}-#{sub}-search"
    defp option_id(id, sub, target), do: "#custom-field-sections-#{id}-#{sub}-opt-#{target.id}"

    test "renders one picker per item, with distinct ids and search names", ctx do
      assert has_element?(ctx.lv, search_id(@hero, "link"))
      assert has_element?(ctx.lv, search_id(@hero2, "link"))

      names =
        ctx.lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("input[data-ref-search]")
        |> LazyHTML.attribute("name")
        |> Enum.filter(&String.contains?(&1, "sections"))

      assert length(names) == 2
      assert names == Enum.uniq(names)
    end

    test "picks a record, saves its snapshot, and shows it after a reload", ctx do
      ctx.lv |> element(search_id(@hero, "link")) |> render_focus()
      ctx.lv |> element(option_id(@hero, "link", ctx.target)) |> render_click()

      assert ref_input(ctx.lv, @hero, "link") == [ctx.target.id]
      assert ref_input(ctx.lv, @hero2, "link") == [""]

      save(ctx.lv)

      assert %{"link" => %{"id" => id, "type" => "page", "title" => "Target page"}} =
               item(ctx, @hero)

      assert id == ctx.target.id

      {:ok, lv, html} =
        ctx.conn
        |> recycle()
        |> signed_in(ctx.admin)
        |> live(~p"/editor/content/page/#{ctx.page.id}")

      assert html =~ "Target page"
      assert ref_input(lv, @hero, "link") == [ctx.target.id]
    end

    test "clears", ctx do
      ctx.lv |> element(search_id(@hero, "link")) |> render_focus()
      ctx.lv |> element(option_id(@hero, "link", ctx.target)) |> render_click()
      save(ctx.lv)
      assert %{"link" => %{"id" => _}} = item(ctx, @hero)

      ctx.lv
      |> element("#custom-field-sections-#{@hero}-link [data-ref-remove]")
      |> render_click()

      assert ref_input(ctx.lv, @hero, "link") == [""]
      save(ctx.lv)
      refute match?(%{"link" => %{"id" => _}}, item(ctx, @hero))
    end

    test "a forged picker message writes only a reference sub-field it resolves", ctx do
      picker = KilnCMSWeb.ContentEditor.ReferencePicker
      gone = Ecto.UUID.generate()

      for {at, sub} <- [
            {"sections/#{gone}", "link"},
            {"sections/#{@hero}", "image"},
            {"sections/#{@hero}", "headline"},
            {"sections/#{@hero}", "nope"},
            {"sections", "link"},
            {"sections/#{@columns}", "link"}
          ] do
        send(ctx.lv.pid, {picker, {:item, at, sub, :put, ctx.target.id}})
      end

      send(ctx.lv.pid, {picker, {:item, "sections/#{@hero}", "link", :explode, ctx.target.id}})
      render(ctx.lv)
      save(ctx.lv)

      refute Map.has_key?(item(ctx, @hero), "link")
      refute Map.has_key?(item(ctx, @hero), "image")
      assert item(ctx, @hero)["headline"] == "One"
      assert Process.alive?(ctx.lv.pid)
    end
  end

  describe "a field the editor's write grant leaves out" do
    test "renders disabled, and every item picker event changes nothing", ctx do
      editor = authed_user(:editor, %{field_grants: %{"page" => ["title"]}})

      {:ok, lv, _html} =
        ctx.conn
        |> recycle()
        |> signed_in(editor)
        |> live(~p"/editor/content/page/#{ctx.page.id}")

      assert has_element?(lv, "fieldset[disabled] #cf-media-sections-#{@hero}-image")

      open_media(lv, "sections/#{@hero}", "image")
      pick_media(lv, "sections/#{@hero}", "image", ctx.picture.id)
      render_hook(lv, "clear_item_media", %{"at" => "sections/#{@hero}", "field" => "image"})

      send(
        lv.pid,
        {KilnCMSWeb.ContentEditor.ReferencePicker,
         {:item, "sections/#{@hero}", "link", :put, ctx.target.id}}
      )

      assert media_input(lv, @hero, "image") == [""]
      assert ref_input(lv, @hero, "link") == [""]
    end
  end
end
