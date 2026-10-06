defmodule KilnCMSWeb.SharedFieldWritesTest do
  @moduledoc """
  A write that changes a `:shared` field on a translation is refused (#1860,
  `KilnCMS.I18n.Validations.SharedFieldsReadOnly`): on every kind of shared
  field, through the code interface, JSON:API, GraphQL, `:autosave` and the
  working copy — while the shared-value copy itself, the source variant's own
  writes, and a translation that predates a field becoming shared keep
  working.

  The test config runs `en` (the default), `fr` and `es`. `async: false`: a
  case opts the page type's `seo_image` in through the operator config, which
  is VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations
  alias KilnCMS.I18n.SharedFieldsWorker

  @accept "application/vnd.api+json"

  setup do
    previous = Application.get_env(:kiln_cms, :i18n)

    Application.put_env(
      :kiln_cms,
      :i18n,
      Keyword.put(previous, :field_localization, page: [shared: [:seo_image]])
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, :i18n, previous)
      KilnCMS.Cache.bust_locale_fallbacks(Accounts.default_org_id())
    end)

    actor = admin()
    price = field(actor, "price", :shared)
    note = field(actor, "note", :localized)

    {en, fr} =
      document(actor, %{
        seo_image: "https://example.com/en.png",
        custom_fields: %{"price" => "10", "note" => "Hello"},
        blocks: [card(%{})]
      })

    %{actor: actor, price: price, note: note, en: en, fr: fr}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sfw-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sfw-#{System.unique_integer([:positive])}"

  defp field(actor, name, localization) do
    CMS.create_field_definition!(
      %{content_type: :page, name: name, label: name, localization: localization},
      actor: actor
    )
  end

  defp card(attrs) do
    Map.merge(
      %{"_type" => "product_card", "name" => "Shoe", "image_url" => "a.png", "price" => 10},
      attrs
    )
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp card_of(page) do
    [%Ash.Union{type: :product_card, value: card}] = reload(page).blocks
    card
  end

  # An English source and its French translation (same slug, same block ids),
  # both published.
  defp document(actor, attrs) do
    en =
      CMS.create_page!(Map.merge(%{title: "Product", slug: slug(), locale: "en"}, attrs),
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)
    fr = CMS.publish_page!(fr, %{}, actor: actor)
    {reload(en), reload(fr)}
  end

  defp messages(%{errors: errors}), do: Enum.map(errors, &Exception.message/1)

  defp refused?(result, pattern) do
    case result do
      {:error, error} -> Enum.any?(messages(error), &(&1 =~ pattern))
      {:ok, _} -> false
    end
  end

  defp key(actor) do
    actor.id
    |> Accounts.mint_api_key!(
      "shared-fields",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: actor
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp patch_json(page, attrs, key) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> patch(
        "/api/json/pages/#{page.id}",
        Jason.encode!(%{data: %{type: "page", id: page.id, attributes: attrs}})
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp gql(query, variables, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  describe "on a translation" do
    test "a shared record attribute is refused, naming the field and the source locale", ctx do
      result =
        CMS.update_page(reload(ctx.fr), %{seo_image: "https://example.com/fr.png"},
          actor: ctx.actor
        )

      assert {:error, %Ash.Error.Invalid{errors: [error]}} = result
      assert %Ash.Error.Changes.InvalidAttribute{field: :seo_image} = error
      assert Exception.message(error) =~ "seo_image"
      assert Exception.message(error) =~ "en version"
      assert reload(ctx.fr).seo_image == "https://example.com/en.png"

      # Clearing it is a change too.
      assert refused?(CMS.update_page(reload(ctx.fr), %{seo_image: nil}, actor: ctx.actor), "en")
    end

    test "a shared custom field is refused; a localized one, and leaving it out, pass", ctx do
      result =
        CMS.update_page(reload(ctx.fr), %{custom_fields: %{"price" => "12"}}, actor: ctx.actor)

      assert {:error, %Ash.Error.Invalid{errors: [error]}} = result
      assert %Ash.Error.Changes.InvalidAttribute{field: :custom_fields} = error
      assert Exception.message(error) =~ ~s("price")
      assert Exception.message(error) =~ "en version"

      # Removing it is a change too.
      assert refused?(
               CMS.update_page(reload(ctx.fr), %{custom_fields: %{"price" => ""}},
                 actor: ctx.actor
               ),
               "price"
             )

      fr =
        CMS.update_page!(reload(ctx.fr), %{custom_fields: %{"note" => "Bonjour"}},
          actor: ctx.actor
        )

      assert fr.custom_fields == %{"price" => "10", "note" => "Bonjour"}
    end

    test "a shared block field is refused by block id; a localized one passes", ctx do
      fr_card = card_of(ctx.fr)

      result =
        CMS.update_page(
          reload(ctx.fr),
          %{blocks: [card(%{"_id" => fr_card.id, "image_url" => "fr.png"})]},
          actor: ctx.actor
        )

      assert {:error, %Ash.Error.Invalid{errors: [error]}} = result
      assert %Ash.Error.Changes.InvalidAttribute{field: :blocks} = error
      assert Exception.message(error) =~ "product_card.image_url"
      assert Exception.message(error) =~ fr_card.id
      assert Exception.message(error) =~ "en version"

      CMS.update_page!(
        reload(ctx.fr),
        %{blocks: [card(%{"_id" => fr_card.id, "name" => "Chaussure"})]},
        actor: ctx.actor
      )

      assert card_of(ctx.fr).name == "Chaussure"
      assert card_of(ctx.fr).image_url == "a.png"
    end

    test "a block the source does not hold is the translation's own", ctx do
      fr_card = card_of(ctx.fr)

      fr =
        CMS.update_page!(
          reload(ctx.fr),
          %{
            blocks: [
              card(%{"_id" => fr_card.id}),
              card(%{"name" => "Extra", "image_url" => "extra.png", "price" => 99})
            ]
          },
          actor: ctx.actor
        )

      assert [_, %Ash.Union{value: %{image_url: "extra.png"}}] = fr.blocks
    end

    test "a write that leaves shared fields alone, or re-sends them, passes", ctx do
      fr = reload(ctx.fr)
      fr_card = card_of(fr)

      fr =
        CMS.update_page!(
          fr,
          %{
            title: "Produit",
            seo_image: fr.seo_image,
            custom_fields: %{"price" => "10", "note" => "Salut"},
            blocks: [card(%{"_id" => fr_card.id, "name" => "Chaussure"})]
          },
          actor: ctx.actor
        )

      assert fr.title == "Produit"
    end

    test "with no source variant, nothing is refused", ctx do
      fr =
        CMS.create_page!(
          %{title: "Seul", slug: slug(), locale: "fr", custom_fields: %{"price" => "1"}},
          actor: ctx.actor
        )

      fr =
        CMS.update_page!(
          fr,
          %{seo_image: "https://example.com/fr.png", custom_fields: %{"price" => "2"}},
          actor: ctx.actor
        )

      assert fr.seo_image == "https://example.com/fr.png"
      assert fr.custom_fields["price"] == "2"
    end

    test ":autosave on a draft translation is refused the same way", ctx do
      fr = CMS.unpublish_page!(reload(ctx.fr), %{}, actor: ctx.actor)

      result =
        fr
        |> Ash.Changeset.for_update(:autosave, %{custom_fields: %{"price" => "12"}},
          actor: ctx.actor,
          tenant: fr.org_id
        )
        |> Ash.update()

      assert refused?(result, ~s("price"))
    end

    test "the working copy refuses a shared value, in the held body and the held fields", ctx do
      fr = reload(ctx.fr)
      fr_card = card_of(fr)

      body =
        CMS.save_page_working_copy(
          fr,
          %{
            working_title: fr.title,
            working_blocks: [card(%{"_id" => fr_card.id, "price" => 11})]
          },
          actor: ctx.actor,
          tenant: fr.org_id
        )

      assert refused?(body, "product_card.price")

      fields =
        CMS.save_page_working_copy(
          fr,
          %{working_title: fr.title, fields: %{"custom_fields" => %{"price" => "12"}}},
          actor: ctx.actor,
          tenant: fr.org_id
        )

      assert refused?(fields, ~s("price"))

      # A localized edit in the copy still saves.
      assert {:ok, _} =
               CMS.save_page_working_copy(
                 fr,
                 %{
                   working_title: "Produit",
                   working_blocks: [card(%{"_id" => fr_card.id, "name" => "Chaussure"})]
                 },
                 actor: ctx.actor,
                 tenant: fr.org_id
               )
    end
  end

  describe "what still writes shared fields" do
    test "the source variant's own writes, and the copy that carries them over", ctx do
      en_card = card_of(ctx.en)

      en =
        CMS.update_page!(
          reload(ctx.en),
          %{
            seo_image: "https://example.com/new.png",
            custom_fields: %{"price" => "20"},
            blocks: [card(%{"_id" => en_card.id, "image_url" => "new.png", "price" => 12})]
          },
          actor: ctx.actor
        )

      # `:sync_shared_fields`, as the `:localization` system actor.
      assert :ok =
               SharedFieldsWorker.perform(%Oban.Job{
                 args: %{"org_id" => en.org_id, "type" => "page", "id" => en.id}
               })

      fr = reload(ctx.fr)
      assert fr.seo_image == "https://example.com/new.png"
      assert fr.custom_fields["price"] == "20"
      assert card_of(fr).image_url == "new.png"
      assert card_of(fr).price == 12
    end

    test "a translation may be set to the source's current value", ctx do
      en_card = card_of(ctx.en)

      # The source changes but has not been copied over yet.
      CMS.update_page!(
        reload(ctx.en),
        %{
          seo_image: "https://example.com/new.png",
          custom_fields: %{"price" => "20"},
          blocks: [card(%{"_id" => en_card.id, "image_url" => "new.png"})]
        },
        actor: ctx.actor
      )

      fr =
        CMS.update_page!(
          reload(ctx.fr),
          %{
            seo_image: "https://example.com/new.png",
            custom_fields: %{"price" => "20"},
            blocks: [card(%{"_id" => en_card.id, "image_url" => "new.png"})]
          },
          actor: ctx.actor
        )

      assert fr.seo_image == "https://example.com/new.png"
      assert fr.custom_fields["price"] == "20"
    end
  end

  describe "a translation that predates the field becoming shared" do
    test "keeps its own value through other writes, and may only move it to the source's",
         ctx do
      # `note` is localized, and the French page has its own value...
      fr =
        CMS.update_page!(reload(ctx.fr), %{custom_fields: %{"note" => "Bonjour"}},
          actor: ctx.actor
        )

      # ...until the field is switched to shared.
      CMS.update_field_definition!(ctx.note, %{localization: :shared}, actor: ctx.actor)

      # An unrelated write passes, and so does re-sending the value it holds.
      fr = CMS.update_page!(fr, %{title: "Produit"}, actor: ctx.actor)

      fr =
        CMS.update_page!(fr, %{custom_fields: %{"note" => "Bonjour", "price" => "10"}},
          actor: ctx.actor
        )

      assert fr.custom_fields["note"] == "Bonjour"

      # A third value is refused: the next copy would overwrite it.
      assert refused?(
               CMS.update_page(fr, %{custom_fields: %{"note" => "Salut"}}, actor: ctx.actor),
               ~s("note")
             )

      # The source's value is not.
      fr = CMS.update_page!(fr, %{custom_fields: %{"note" => "Hello"}}, actor: ctx.actor)
      assert fr.custom_fields["note"] == "Hello"
    end
  end

  describe "values the caller did not write" do
    test "a default filled into a shared custom field is not refused", ctx do
      # Defined after both variants were written, so neither holds the key; a
      # custom-field write on the translation fills in the default.
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "badge",
          label: "Badge",
          localization: :shared,
          default: "new"
        },
        actor: ctx.actor
      )

      fr =
        CMS.update_page!(reload(ctx.fr), %{custom_fields: %{"note" => "Bonjour"}},
          actor: ctx.actor
        )

      assert fr.custom_fields["badge"] == "new"
      refute Map.has_key?(reload(ctx.en).custom_fields, "badge")
    end
  end

  describe "over HTTP" do
    test "a JSON:API PATCH is refused with the field and the source locale", ctx do
      key = key(ctx.actor)

      assert {400, %{"errors" => [error]}} =
               patch_json(ctx.fr, %{seo_image: "https://example.com/fr.png"}, key)

      assert error["source"]["pointer"] == "/data/attributes/seo_image"
      assert error["detail"] =~ "en version"

      assert {400, %{"errors" => [error]}} =
               patch_json(ctx.fr, %{custom_fields: %{"price" => "12"}}, key)

      assert error["detail"] =~ ~s("price")

      assert reload(ctx.fr).seo_image == "https://example.com/en.png"
      assert reload(ctx.fr).custom_fields["price"] == "10"

      # A localized field on the same translation still writes.
      assert {200, _} = patch_json(ctx.fr, %{title: "Produit"}, key)
    end

    test "a GraphQL updatePage that changes a shared block field is refused", ctx do
      fr_card = card_of(ctx.fr)

      body =
        gql(
          """
          mutation ($id: ID!, $input: UpdatePageInput!) {
            updatePage(id: $id, input: $input) {
              result { id }
              errors { fields message }
            }
          }
          """,
          %{
            id: ctx.fr.id,
            # `blockTree` is a list of JSON strings on the GraphQL surface.
            input: %{
              blockTree: [Jason.encode!(card(%{"_id" => fr_card.id, "image_url" => "fr.png"}))]
            }
          },
          key(ctx.actor)
        )

      assert body["data"]["updatePage"]["result"] == nil
      assert [error] = body["data"]["updatePage"]["errors"]
      assert error["message"] =~ "product_card.image_url"
      assert error["message"] =~ "en version"
      assert card_of(ctx.fr).image_url == "a.png"
    end
  end
end
