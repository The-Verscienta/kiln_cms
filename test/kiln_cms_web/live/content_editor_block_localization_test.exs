defmodule KilnCMSWeb.ContentEditorBlockLocalizationTest do
  @moduledoc """
  A site opts a core block's fields into `:shared` / `:fallback` with
  `config :kiln_cms, :i18n, block_fields: %{...}` (#2270). The bespoke
  `image`, `video` and `audio` editors must honour it as `dsl_block_fields`
  does: read-only inputs, no picker, an inherited placeholder and the same
  note. A crafted picker event must not get around it (#1896).

  `async: false`: the case sets `:i18n` application env, which is VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, :i18n)

    on_exit(fn ->
      Application.put_env(:kiln_cms, :i18n, previous)
      KilnCMS.Cache.bust_locale_fallbacks(KilnCMS.Accounts.default_org_id())
    end)

    %{previous: previous}
  end

  defp configure(%{previous: previous}, block_fields),
    do: Application.put_env(:kiln_cms, :i18n, Keyword.put(previous, :block_fields, block_fields))

  defp admin do
    email = "bfloc-ed-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/content/page/#{page.id}")

    {lv, html}
  end

  defp slug, do: "bfloc-ed-#{System.unique_integer([:positive])}"

  # An EN page and its FR translation, each holding `block` (the translation
  # with `fr_attrs` merged over it), created before any config is set.
  defp document(actor, block, fr_attrs \\ %{}) do
    en =
      CMS.create_page!(%{title: "Product", slug: slug(), locale: "en", blocks: [block]},
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)

    fr =
      if fr_attrs == %{} do
        fr
      else
        [%Ash.Union{value: held}] = fr.blocks

        CMS.update_page!(
          fr,
          %{blocks: [block |> Map.merge(fr_attrs) |> Map.put("_id", held.id)]},
          actor: actor
        )
      end

    {en, fr}
  end

  defp image(attrs \\ %{}) do
    Map.merge(
      %{
        "_type" => "image",
        "url" => "https://example.com/en.png",
        "alt" => "A shoe",
        "caption" => "Leather"
      },
      attrs
    )
  end

  defp block_id(record) do
    [%Ash.Union{value: block}] = record.blocks
    block.id
  end

  @shared_image %{"image" => [shared: [:media_id, :url], fallback: [:alt, :caption]]}

  describe "image" do
    test "shared url is read-only on a translation and its picker is unavailable",
         %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, image())
      configure(ctx, @shared_image)

      {lv, _html} = open_editor(conn, actor, fr)

      assert has_element?(lv, "input[name$='[url]'][readonly]")
      assert has_element?(lv, "button[phx-click=open_picker][disabled]")
      assert has_element?(lv, "[data-localization=shared]", "Shared: edited in the EN version.")
    end

    test "an empty fallback alt and caption show the value they inherit", %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, image(), %{"alt" => "", "caption" => ""})
      configure(ctx, @shared_image)

      {lv, _html} = open_editor(conn, actor, fr)

      assert has_element?(lv, "input[name$='[alt]'][placeholder='A shoe']")
      assert has_element?(lv, "input[name$='[caption]'][placeholder='Leather']")
      assert has_element?(lv, "[data-localization=fallback]", "readers get the EN value")
      refute has_element?(lv, "input[name$='[alt]'][readonly]")
    end

    test "the source locale is unaffected", %{conn: conn} = ctx do
      actor = admin()
      {en, _fr} = document(actor, image())
      configure(ctx, @shared_image)

      {lv, _html} = open_editor(conn, actor, en)

      refute has_element?(lv, "input[name$='[url]'][readonly]")
      refute has_element?(lv, "button[phx-click=open_picker][disabled]")
      assert has_element?(lv, "button[phx-click=open_picker]")
      assert has_element?(lv, "[data-localization=shared]", "Shared with 1 other locale")
    end

    test "nothing changes without config", %{conn: conn} do
      actor = admin()
      {_en, fr} = document(actor, image(), %{"alt" => ""})

      {lv, _html} = open_editor(conn, actor, fr)

      refute has_element?(lv, "input[readonly]")
      refute has_element?(lv, "button[phx-click=open_picker][disabled]")
      refute has_element?(lv, "[data-localization]")
      refute has_element?(lv, "input[name$='[alt]'][placeholder='A shoe']")
    end

    test "removing the config restores editing", %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, image())
      configure(ctx, @shared_image)
      {lv, _html} = open_editor(conn, actor, fr)
      assert has_element?(lv, "input[name$='[url]'][readonly]")

      configure(ctx, %{})
      {lv, _html} = open_editor(conn, actor, fr)
      refute has_element?(lv, "input[name$='[url]'][readonly]")
    end

    test "a crafted picker event cannot change a shared image on a translation",
         %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, image())
      configure(ctx, @shared_image)
      bid = block_id(fr)

      {lv, _html} = open_editor(conn, actor, fr)

      render_hook(lv, "open_picker", %{"bid" => bid})
      refute has_element?(lv, "[phx-click=pick_image]")

      render_hook(lv, "pick_image", %{
        "index" => "block",
        "bid" => bid,
        "id" => Ash.UUID.generate(),
        "url" => "https://example.com/other.png"
      })

      assert has_element?(lv, "input[name$='[url]'][value='https://example.com/en.png']")
      refute render(lv) =~ "other.png"
    end

    test "the same pick lands on the source", %{conn: conn} = ctx do
      actor = admin()
      {en, _fr} = document(actor, image())
      configure(ctx, @shared_image)
      bid = block_id(en)

      {lv, _html} = open_editor(conn, actor, en)

      render_hook(lv, "pick_image", %{
        "index" => "block",
        "bid" => bid,
        "id" => Ash.UUID.generate(),
        "url" => "https://example.com/other.png"
      })

      assert has_element?(lv, "input[name$='[url]'][value='https://example.com/other.png']")
    end
  end

  describe "image nested in columns" do
    test "shared url is read-only and an empty fallback alt shows its placeholder",
         %{conn: conn} = ctx do
      actor = admin()
      child_id = Ash.UUID.generate()

      cols = fn alt ->
        %{
          "_type" => "columns",
          "columns" => [
            %{
              "blocks" => [
                %{
                  "_type" => "image",
                  "id" => child_id,
                  "url" => "https://example.com/en.png",
                  "alt" => alt
                }
              ]
            }
          ]
        }
      end

      en =
        CMS.create_page!(
          %{title: "Cols", slug: slug(), locale: "en", blocks: [cols.("Nested shoe")]},
          actor: actor
        )

      en = CMS.publish_page!(en, %{}, actor: actor)
      fr = Translations.create_translation!(:page, en, "fr", actor: actor)
      [%Ash.Union{value: held}] = fr.blocks

      fr =
        CMS.update_page!(
          fr,
          %{blocks: [Map.put(cols.(""), "_id", held.id)]},
          actor: actor
        )

      configure(ctx, @shared_image)
      {lv, _html} = open_editor(conn, actor, fr)

      assert has_element?(lv, "#child-#{child_id} input[phx-value-field=url][readonly]")

      assert has_element?(
               lv,
               "#child-#{child_id} input[phx-value-field=alt][placeholder='Nested shoe']"
             )

      refute has_element?(lv, "#child-#{child_id} input[phx-value-field=alt][readonly]")
      assert has_element?(lv, "#child-#{child_id} [data-localization=shared]")
    end
  end

  describe "crafted col_update_child" do
    defp nested_doc(actor) do
      child_id = Ash.UUID.generate()

      cols = %{
        "_type" => "columns",
        "columns" => [
          %{
            "blocks" => [
              %{
                "_type" => "image",
                "id" => child_id,
                "url" => "https://example.com/en.png",
                "alt" => "Nested shoe"
              }
            ]
          }
        ]
      }

      en =
        CMS.create_page!(%{title: "Cols", slug: slug(), locale: "en", blocks: [cols]},
          actor: actor
        )

      en = CMS.publish_page!(en, %{}, actor: actor)
      fr = Translations.create_translation!(:page, en, "fr", actor: actor)
      {child_id, en, fr}
    end

    defp craft(lv, field, value) do
      # a browser's first phx-change; it seeds the form's block params
      lv |> form("#page-editor") |> render_change()
      html = render(lv)
      [_, bid] = Regex.run(~r/phx-value-id="([^"]+)"[^>]*phx-value-child/, html)
      [_, child] = Regex.run(~r/id="child-([^"]+)"/, html)

      render_hook(lv, "col_update_child", %{
        "id" => bid,
        "child" => child,
        "field" => field,
        "value" => value
      })
    end

    test "is refused for a shared field on a translation, allowed for an unshared one",
         %{conn: conn} = ctx do
      actor = admin()
      {child_id, _en, fr} = nested_doc(actor)
      configure(ctx, @shared_image)
      {lv, _html} = open_editor(conn, actor, fr)

      craft(lv, "url", "https://evil.example/x.png")
      refute render(lv) =~ "evil.example"

      assert has_element?(
               lv,
               "#child-#{child_id} input[phx-value-field=url][value='https://example.com/en.png']"
             )

      craft(lv, "caption_unused", "x")
      craft(lv, "alt", "Edited alt")
      assert render(lv) =~ "Edited alt"
    end

    test "is allowed on the EN source", %{conn: conn} = ctx do
      actor = admin()
      {_child_id, en, _fr} = nested_doc(actor)
      configure(ctx, @shared_image)
      {lv, _html} = open_editor(conn, actor, en)

      craft(lv, "url", "https://example.com/new.png")
      assert render(lv) =~ "https://example.com/new.png"
    end

    test "changes nothing without block_fields config", %{conn: conn} do
      actor = admin()
      {_child_id, _en, fr} = nested_doc(actor)
      {lv, _html} = open_editor(conn, actor, fr)

      craft(lv, "url", "https://example.com/free.png")
      assert render(lv) =~ "https://example.com/free.png"
    end
  end

  describe "video" do
    @video %{
      "_type" => "video",
      "url" => "https://example.com/en.mp4",
      "title" => "Demo",
      "caption" => "Cap",
      "loop" => true
    }

    @shared_video %{
      "video" => [
        shared: [:media_id, :url, :poster_media_id, :poster_url, :loop],
        fallback: [:title, :caption]
      ]
    }

    test "shared fields are locked, pickers disabled, fallbacks inherit", %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, @video, %{"title" => "", "caption" => ""})
      configure(ctx, @shared_video)

      {lv, _html} = open_editor(conn, actor, fr)

      assert has_element?(lv, "input[name$='[url]'][readonly]")
      assert has_element?(lv, "button[phx-value-field=media][disabled]")
      assert has_element?(lv, "button[phx-value-field=poster][disabled]")
      refute has_element?(lv, "button[phx-value-field=captions][disabled]")
      assert has_element?(lv, "input[name$='[title]'][placeholder='Demo']")
      assert has_element?(lv, "input[name$='[caption]'][placeholder='Cap']")
      assert has_element?(lv, "input[type=checkbox][name$='[loop]'][disabled]")
      assert has_element?(lv, "input[type=hidden][name$='[loop]'][value=true]")
      assert has_element?(lv, "[data-localization=shared]", "Shared: edited in the EN version.")
    end

    test "the source and an unconfigured site are unaffected", %{conn: conn} = ctx do
      actor = admin()
      {en, fr} = document(actor, @video)

      {lv, _html} = open_editor(conn, actor, fr)
      refute has_element?(lv, "[data-localization]")
      refute has_element?(lv, "button[phx-click=open_av_picker][disabled]")

      configure(ctx, @shared_video)
      {lv, _html} = open_editor(conn, actor, en)
      refute has_element?(lv, "input[name$='[url]'][readonly]")
      refute has_element?(lv, "button[phx-value-field=media][disabled]")
    end

    test "a crafted picker event cannot open or fill a shared video", %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, @video)
      configure(ctx, @shared_video)
      bid = block_id(fr)

      {lv, _html} = open_editor(conn, actor, fr)

      for field <- ~w(media poster) do
        render_hook(lv, "open_av_picker", %{"bid" => bid, "field" => field})
        refute has_element?(lv, "[phx-click=pick_av]")
      end

      # Captions are not shared here, so that drawer still opens.
      render_hook(lv, "open_av_picker", %{"bid" => bid, "field" => "captions"})
      assert :sys.get_state(lv.pid).socket.assigns.av_picking == {bid, "captions"}
    end
  end

  describe "audio" do
    @audio %{"_type" => "audio", "url" => "https://example.com/en.mp3", "title" => "Song"}

    test "shared url is locked and the picker disabled", %{conn: conn} = ctx do
      actor = admin()
      {_en, fr} = document(actor, @audio, %{"title" => ""})
      configure(ctx, %{"audio" => [shared: [:media_id, :url], fallback: [:title]]})

      {lv, _html} = open_editor(conn, actor, fr)

      assert has_element?(lv, "input[name$='[url]'][readonly]")
      assert has_element?(lv, "button[phx-value-field=media][disabled]")
      assert has_element?(lv, "input[name$='[title]'][placeholder='Song']")
      assert has_element?(lv, "[data-localization=fallback]")
    end

    test "nothing changes without config", %{conn: conn} do
      actor = admin()
      {_en, fr} = document(actor, @audio)

      {lv, _html} = open_editor(conn, actor, fr)

      refute has_element?(lv, "input[readonly]")
      refute has_element?(lv, "[data-localization]")
    end
  end
end
