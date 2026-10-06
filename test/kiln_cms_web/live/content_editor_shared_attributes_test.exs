defmodule KilnCMSWeb.ContentEditorSharedAttributesTest do
  @moduledoc """
  The editor's half of #1860: on a translation, every shared field it can
  edit is locked, so a translator is never offered a change the save would
  refuse (`KilnCMS.I18n.Validations.SharedFieldsReadOnly`).

  The category and the featured image are not text inputs — a select and a
  picker with Remove — and a boolean block field is a checkbox, which ignores
  `readonly`. Each needs its own lock, and the pick/clear events re-check it
  server-side, since a hidden button is not a boundary.

  `async: false`: the page type opts its attributes in through the operator
  config, which is VM-global.
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

    Application.put_env(
      :kiln_cms,
      :i18n,
      Keyword.put(previous, :field_localization,
        page: [shared: [:category_id, :featured_image_id, :seo_image]]
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)

    actor = admin()
    category = CMS.create_category!(%{name: "News", slug: slug()}, actor: actor)
    media = media()
    other = media()

    en =
      CMS.create_page!(
        %{
          title: "Product",
          slug: slug(),
          locale: "en",
          category_id: category.id,
          featured_image_id: media.id,
          blocks: [
            %{
              "_type" => "product_card",
              "name" => "Shoe",
              "image_url" => "a.png",
              "in_stock" => true
            }
          ]
        },
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)

    %{actor: actor, category: category, media: media, other: other, en: en, fr: fr}
  end

  defp admin do
    email = "sfa-ed-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp media do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "sfa-#{System.unique_integer([:positive])}.jpg",
      url: "/uploads/sfa-#{System.unique_integer([:positive])}.jpg",
      alt: "A shoe"
    })
  end

  defp slug, do: "sfa-#{System.unique_integer([:positive])}"

  defp open_editor(conn, user, page) do
    {:ok, lv, html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/content/page/#{page.id}")

    {lv, html}
  end

  defp featured_value(lv, id),
    do: has_element?(lv, ~s(input[type=hidden][name$="[featured_image_id]"][value="#{id}"]))

  test "on a translation the category and featured image are locked", ctx do
    {lv, _html} = open_editor(build_conn(), ctx.actor, ctx.fr)

    # The select is shown disabled; a hidden input re-sends the stored value.
    assert has_element?(lv, ~s(select[name$="[category_id]"][disabled]))

    assert has_element?(
             lv,
             ~s(input[type=hidden][name$="[category_id]"][value="#{ctx.category.id}"])
           )

    refute has_element?(lv, "#category-new")

    refute has_element?(lv, ~s(button[phx-click="open_featured_picker"]))
    refute has_element?(lv, ~s(button[phx-click="clear_featured"]))
    assert featured_value(lv, ctx.media.id)

    # The events re-check the lock: a replayed click changes nothing.
    render_click(lv, "clear_featured", %{})
    assert featured_value(lv, ctx.media.id)

    render_click(lv, "pick_image", %{"index" => "featured", "id" => ctx.other.id})
    assert featured_value(lv, ctx.media.id)

    render_click(lv, "pick_image", %{"index" => "seo_image", "url" => "/uploads/x.jpg"})
    refute render(lv) =~ "/uploads/x.jpg"
  end

  test "on a translation a shared boolean block field is disabled, its value kept", ctx do
    {lv, _html} = open_editor(build_conn(), ctx.actor, ctx.fr)

    assert has_element?(lv, ~s(input[type=checkbox][name$="[in_stock]"][disabled]))

    assert has_element?(
             lv,
             ~s{input[type=hidden][name$="[in_stock]"][value="true"]:not([disabled])}
           )

    # A localized field on the same block stays editable.
    refute has_element?(lv, ~s(input[name$="[name]"][readonly]))
  end

  test "on the source the same controls are editable", ctx do
    {lv, _html} = open_editor(build_conn(), ctx.actor, ctx.en)

    assert has_element?(lv, ~s(select[name$="[category_id]"]))
    refute has_element?(lv, ~s(select[name$="[category_id]"][disabled]))
    assert has_element?(lv, ~s(button[phx-click="open_featured_picker"]))
    assert has_element?(lv, ~s(input[type=checkbox][name$="[in_stock]"]))
    refute has_element?(lv, ~s(input[type=checkbox][name$="[in_stock]"][disabled]))

    render_click(lv, "clear_featured", %{})
    refute featured_value(lv, ctx.media.id)
  end
end
