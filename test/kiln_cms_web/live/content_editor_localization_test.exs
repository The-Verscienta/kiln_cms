defmodule KilnCMSWeb.ContentEditorLocalizationTest do
  @moduledoc """
  Field-level localization in the content editor (#1327): on a translation a
  shared field is read-only and says where it is edited; on the source it
  says who it is shared with; an empty fallback field shows what it inherits.
  A type that opts nothing in shows none of it.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations

  @password "password123456"

  defp admin do
    email = "floc-ed-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/content/page/#{page.id}")

    {lv, html}
  end

  defp slug, do: "floc-ed-#{System.unique_integer([:positive])}"

  defp field(actor, name, localization) do
    CMS.create_field_definition!(
      %{content_type: :page, name: name, label: name, localization: localization},
      actor: actor
    )
  end

  defp document(actor, attrs) do
    en =
      CMS.create_page!(Map.merge(%{title: "Product", slug: slug(), locale: "en"}, attrs),
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)
    {en, fr}
  end

  test "a shared custom field is disabled on a translation and links to the source", %{conn: conn} do
    actor = admin()
    field(actor, "price", :shared)
    {en, fr} = document(actor, %{custom_fields: %{"price" => "10"}})

    {lv, _html} = open_editor(conn, actor, fr)

    assert has_element?(lv, "fieldset[disabled] input[name$='[custom_fields][price]']")
    assert has_element?(lv, "[data-localization=shared]", "Shared: edited in the EN version.")
    assert has_element?(lv, ~s(a[href="/editor/content/page/#{en.id}"]), "Open")
  end

  test "on the source the same field is editable and says it is shared", %{conn: conn} do
    actor = admin()
    field(actor, "price", :shared)
    {en, _fr} = document(actor, %{custom_fields: %{"price" => "10"}})

    {lv, _html} = open_editor(conn, actor, en)

    refute has_element?(lv, "fieldset[disabled] input[name$='[custom_fields][price]']")
    assert has_element?(lv, "input[name$='[custom_fields][price]']")
    assert has_element?(lv, "[data-localization=shared]", "Shared with 1 other locale")
  end

  test "an empty fallback block field shows the value it inherits", %{conn: conn} do
    actor = admin()

    {_en, fr} =
      document(actor, %{
        blocks: [
          %{
            "_type" => "product_card",
            "name" => "Shoe",
            "image_url" => "a.png",
            "caption" => "Waterproof"
          }
        ]
      })

    [%Ash.Union{value: block}] = fr.blocks

    fr =
      CMS.update_page!(
        fr,
        %{
          blocks: [
            %{
              "_type" => "product_card",
              "_id" => block.id,
              "name" => "Chaussure",
              "image_url" => "a.png",
              "caption" => ""
            }
          ]
        },
        actor: actor
      )

    {lv, _html} = open_editor(conn, actor, fr)

    assert has_element?(lv, "input[name$='[caption]'][placeholder='Waterproof']")
    assert has_element?(lv, "[data-localization=fallback]", "readers get the EN value")
    assert has_element?(lv, "input[name$='[image_url]'][readonly]")
    refute has_element?(lv, "input[name$='[name]'][readonly]")
  end

  test "a type that opts nothing in shows no localization notes", %{conn: conn} do
    actor = admin()
    field(actor, "plain", :localized)
    {_en, fr} = document(actor, %{custom_fields: %{"plain" => "x"}})

    {lv, _html} = open_editor(conn, actor, fr)

    refute has_element?(lv, "[data-localization]")
    refute has_element?(lv, "fieldset[disabled] input[name$='[custom_fields][plain]']")
  end
end
