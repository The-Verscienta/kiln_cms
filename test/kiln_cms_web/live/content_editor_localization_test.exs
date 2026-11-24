defmodule KilnCMSWeb.ContentEditorLocalizationTest do
  @moduledoc """
  Field-level localization in the content editor (#1327): on a translation a
  shared field is read-only and says where it is edited; on the source it
  says who it is shared with; an empty fallback field shows what it inherits.
  A type that opts nothing in shows none of it.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations

  @password "password123456"

  # A seeded org, not the default one (#2592): the default org's cached locale
  # fallbacks are one key shared by every async test, and a miss here can join
  # another test's in-flight Courier lookup, which reads on that test's sandbox
  # connection. When that read fails, the chain degrades and the placeholder
  # these tests assert never renders. A seeded org's key is this test's alone.
  setup do
    org = org("floc-ed")
    on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(org.id) end)
    %{org: org}
  end

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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp open_editor(conn, org, user, page) do
    {:ok, lv, html} =
      conn
      |> org_conn(org)
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/content/page/#{page.id}")

    {lv, html}
  end

  defp slug, do: "floc-ed-#{System.unique_integer([:positive])}"

  defp field(org, actor, name, localization) do
    CMS.create_field_definition!(
      %{content_type: :page, name: name, label: name, localization: localization},
      actor: actor,
      tenant: org
    )
  end

  defp document(org, actor, attrs) do
    en =
      CMS.create_page!(Map.merge(%{title: "Product", slug: slug(), locale: "en"}, attrs),
        actor: actor,
        tenant: org
      )

    en = CMS.publish_page!(en, %{}, actor: actor, tenant: org)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor, tenant: org)
    {en, fr}
  end

  test "a shared custom field is disabled on a translation and links to the source", %{
    conn: conn,
    org: org
  } do
    actor = admin()
    field(org, actor, "cel_price", :shared)
    {en, fr} = document(org, actor, %{custom_fields: %{"cel_price" => "10"}})

    {lv, _html} = open_editor(conn, org, actor, fr)

    assert has_element?(lv, "fieldset[disabled] input[name$='[custom_fields][cel_price]']")
    assert has_element?(lv, "[data-localization=shared]", "Shared: edited in the EN version.")
    assert has_element?(lv, ~s(a[href="/editor/content/page/#{en.id}"]), "Open")
  end

  test "on the source the same field is editable and says it is shared", %{conn: conn, org: org} do
    actor = admin()
    field(org, actor, "cel_price", :shared)
    {en, _fr} = document(org, actor, %{custom_fields: %{"cel_price" => "10"}})

    {lv, _html} = open_editor(conn, org, actor, en)

    refute has_element?(lv, "fieldset[disabled] input[name$='[custom_fields][cel_price]']")
    assert has_element?(lv, "input[name$='[custom_fields][cel_price]']")
    assert has_element?(lv, "[data-localization=shared]", "Shared with 1 other locale")
  end

  test "an empty fallback block field shows the value it inherits", %{conn: conn, org: org} do
    actor = admin()

    {_en, fr} =
      document(org, actor, %{
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
        actor: actor,
        tenant: org
      )

    {lv, _html} = open_editor(conn, org, actor, fr)

    assert has_element?(lv, "input[name$='[caption]'][placeholder='Waterproof']")
    assert has_element?(lv, "[data-localization=fallback]", "readers get the EN value")
    assert has_element?(lv, "input[name$='[image_url]'][readonly]")
    refute has_element?(lv, "input[name$='[name]'][readonly]")
  end

  test "a fallback custom field with its own value renders and inherits nothing", %{
    conn: conn,
    org: org
  } do
    actor = admin()
    field(org, actor, "caption", :fallback)
    {en, fr} = document(org, actor, %{custom_fields: %{"caption" => "Waterproof"}})

    # A value of its own on either side: nothing is inherited, which once
    # answered `%{}` instead of `nil` and crashed the note's render.
    for record <- [en, fr] do
      {lv, _html} = open_editor(conn, org, actor, record)

      assert has_element?(lv, "input[name$='[custom_fields][caption]'][value='Waterproof']")
      assert has_element?(lv, "[data-localization=fallback]", "Leave empty to inherit")
    end
  end

  test "an empty fallback custom field shows the value it inherits", %{conn: conn, org: org} do
    actor = admin()
    field(org, actor, "caption", :fallback)
    {_en, fr} = document(org, actor, %{custom_fields: %{"caption" => "Waterproof"}})
    fr = CMS.update_page!(fr, %{custom_fields: %{"caption" => ""}}, actor: actor, tenant: org)

    {lv, _html} = open_editor(conn, org, actor, fr)

    assert has_element?(lv, "input[name$='[custom_fields][caption]'][placeholder='Waterproof']")
    assert has_element?(lv, "[data-localization=fallback]", "readers get the EN value")
  end

  test "a type that opts nothing in shows no localization notes", %{conn: conn, org: org} do
    actor = admin()
    field(org, actor, "plain", :localized)
    {_en, fr} = document(org, actor, %{custom_fields: %{"plain" => "x"}})

    {lv, _html} = open_editor(conn, org, actor, fr)

    refute has_element?(lv, "[data-localization]")
    refute has_element?(lv, "fieldset[disabled] input[name$='[custom_fields][plain]']")
  end
end
