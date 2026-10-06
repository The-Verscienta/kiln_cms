defmodule KilnCMSWeb.FieldLocalizationDeliveryTest do
  @moduledoc """
  Field-level localization (#1327) on every delivery surface: the public page,
  the fired-artifact API, JSON:API and GraphQL — and, for a document whose type
  opts nothing in, responses whose shape is exactly what it was before
  (golden key sets).

  The test config runs `en` (default), `fr` and `es` with no site chain, so a
  French page inherits from English.

  `async: false`: the delivery caches and the fallback chains are per org, and
  this runs on the default org every other delivery test shares.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations

  @schema KilnCMSWeb.GraphqlSchema

  setup do
    KilnCMS.Cache.bust_published()
    on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(Accounts.default_org_id()) end)
    %{actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "floc-web-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "flocweb-#{System.unique_integer([:positive])}"

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp card(attrs) do
    Map.merge(
      %{"_type" => "product_card", "name" => "Shoe", "image_url" => "a.png", "price" => 10},
      attrs
    )
  end

  # English source, French translation (sharing block ids), both published and
  # fired. `fr_attrs` is applied to the French variant before it publishes.
  defp document(actor, en_attrs, fr_attrs_fun) do
    en =
      CMS.create_page!(Map.merge(%{title: "Product", slug: slug(), locale: "en"}, en_attrs),
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)
    fr = CMS.update_page!(fr, fr_attrs_fun.(fr), actor: actor)
    fr = CMS.publish_page!(fr, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    {reload(en), reload(fr)}
  end

  defp json_api(path),
    do: build_conn() |> put_req_header("accept", "application/vnd.api+json") |> get(path)

  defp gql(query, variables),
    do:
      Absinthe.run(query, @schema,
        variables: variables,
        context: %{tenant: Accounts.default_org_id()}
      )

  defp tagline(actor) do
    CMS.create_field_definition!(
      %{content_type: :page, name: "tagline", label: "Tagline", localization: :fallback},
      actor: actor
    )
  end

  describe "a type that opts a field in" do
    setup %{actor: actor} do
      tagline(actor)

      {en, fr} =
        document(
          actor,
          %{
            custom_fields: %{"tagline" => "Made by hand"},
            blocks: [card(%{"caption" => "Waterproof"})]
          },
          fn fr ->
            [%Ash.Union{value: block}] = fr.blocks

            %{
              custom_fields: %{"tagline" => ""},
              blocks: [card(%{"_id" => block.id, "name" => "Chaussure", "caption" => ""})]
            }
          end
        )

      %{en: en, fr: fr}
    end

    test "the fired artifact carries the values and names what it filled", %{conn: conn, fr: fr} do
      body = conn |> get(~p"/api/content/page/#{fr.slug}?locale=fr") |> json_response(200)

      assert body["locale"] == "fr"
      assert body["custom_fields"]["tagline"] == "Made by hand"
      assert [%{"name" => "Chaussure", "caption" => "Waterproof"}] = body["blocks"]
      [%{"_id" => block_id}] = body["blocks"]

      assert body["inherited_fields"] == %{
               "custom_fields" => %{"tagline" => "en"},
               "blocks" => %{block_id => %{"caption" => "en"}}
             }
    end

    test "JSON:API serves inherited_fields when asked, and stores nothing", %{fr: fr} do
      conn =
        json_api(
          "/api/json/pages/by-slug/#{fr.slug}?locale=fr&fields[page]=title,custom_fields,inherited_fields"
        )

      assert conn.status == 200
      attributes = Jason.decode!(conn.resp_body)["data"]["attributes"]

      assert attributes["inherited_fields"] == %{
               "custom_fields" => %{"tagline" => %{"value" => "Made by hand", "locale" => "en"}}
             }

      # The row's own value is still what the variant stores.
      assert attributes["custom_fields"]["tagline"] in [nil, ""]

      default = json_api("/api/json/pages/by-slug/#{fr.slug}?locale=fr")

      refute Map.has_key?(
               Jason.decode!(default.resp_body)["data"]["attributes"],
               "inherited_fields"
             )
    end

    test "GraphQL serves inheritedFields when asked", %{fr: fr} do
      query = """
      query ($slug: String!) {
        pageBySlug(slug: $slug, locale: "fr") { locale inheritedFields }
      }
      """

      assert {:ok,
              %{data: %{"pageBySlug" => %{"locale" => "fr", "inheritedFields" => inherited}}}} =
               gql(query, %{"slug" => fr.slug})

      inherited = if is_binary(inherited), do: Jason.decode!(inherited), else: inherited

      assert inherited == %{
               "custom_fields" => %{"tagline" => %{"value" => "Made by hand", "locale" => "en"}}
             }
    end
  end

  # A core type opts its record attributes in through the operator config,
  # since a site cannot edit `KilnCMS.CMS.Page`'s `use` line.
  describe "record attributes opted in through config" do
    setup %{actor: actor} do
      previous = Application.get_env(:kiln_cms, :i18n)

      Application.put_env(
        :kiln_cms,
        :i18n,
        Keyword.put(previous, :field_localization,
          page: [shared: [:seo_image], fallback: [:seo_description]]
        )
      )

      on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)

      {en, fr} =
        document(
          actor,
          %{seo_description: "Handmade leather shoes", seo_image: "https://example.com/en.png"},
          # The social image is shared, so the translation keeps the one it was
          # created with: setting its own is refused (#1860).
          fn _fr -> %{seo_description: nil} end
        )

      %{en: en, fr: fr, actor: actor}
    end

    test "the public page's meta description inherits along the chain", %{conn: conn, fr: fr} do
      html = conn |> get("/fr/#{fr.slug}") |> html_response(200)
      assert html =~ ~s(<meta name="description" content="Handmade leather shoes">)
    end

    test "a shared social image follows the source, through the copy job", %{
      en: en,
      fr: fr,
      actor: actor
    } do
      en = CMS.update_page!(en, %{seo_image: "https://example.com/new.png"}, actor: actor)

      KilnCMS.I18n.SharedFieldsWorker.perform(%Oban.Job{
        args: %{"org_id" => en.org_id, "type" => "page", "id" => en.id}
      })

      assert reload(fr).seo_image == "https://example.com/new.png"
    end

    test "JSON:API inherited_fields reports the record attribute", %{fr: fr} do
      conn =
        json_api(
          "/api/json/pages/by-slug/#{fr.slug}?locale=fr&fields[page]=title,inherited_fields"
        )

      assert Jason.decode!(conn.resp_body)["data"]["attributes"]["inherited_fields"] == %{
               "seo_description" => %{"value" => "Handmade leather shoes", "locale" => "en"}
             }
    end
  end

  # Golden key sets: what each surface returned before field-level
  # localization existed. A document whose type opts nothing in must come back
  # with exactly these keys — `inherited_fields` appears nowhere unless asked
  # for, and only on a type that can inherit.
  describe "a document that opts nothing in" do
    @artifact_keys ~w(blocks custom_fields id locale slug title type)

    setup %{actor: actor} do
      {en, fr} =
        document(actor, %{blocks: [%{"_type" => "heading", "text" => "Hello"}]}, fn _fr ->
          %{title: "Produit"}
        end)

      %{en: en, fr: fr}
    end

    test "the fired artifact has exactly the keys it always had", %{conn: conn, fr: fr} do
      body = conn |> get(~p"/api/content/page/#{fr.slug}?locale=fr") |> json_response(200)
      assert body |> Map.keys() |> Enum.sort() == @artifact_keys
    end

    test "JSON:API attributes are the public attributes, and no calculation", %{fr: fr} do
      conn = json_api("/api/json/pages/by-slug/#{fr.slug}?locale=fr")
      attributes = Jason.decode!(conn.resp_body)["data"]["attributes"]

      # `id` is the resource object's own member, not an attribute.
      public =
        CMS.Page
        |> Ash.Resource.Info.public_attributes()
        |> Enum.map(&to_string(&1.name))
        |> Kernel.--(["id"])
        |> Enum.sort()

      assert attributes |> Map.keys() |> Enum.sort() == public
      refute Map.has_key?(attributes, "inherited_fields")
    end

    test "nothing is inherited, and nothing is copied", %{en: en, fr: fr} do
      assert KilnCMS.I18n.FieldFallback.inherited_values(fr) == %{}
      CMS.update_page!(en, %{title: "Product v2"}, actor: admin())
      assert reload(fr).title == "Produit"
    end
  end
end
