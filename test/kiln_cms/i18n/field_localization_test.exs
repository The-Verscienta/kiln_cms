defmodule KilnCMS.I18n.FieldLocalizationTest do
  @moduledoc """
  Field-level localization over locale variants (#1327, Design A in
  `docs/field-level-localization.md`): the three declarations, the shared-value
  copy on publish (and what it does to a sibling's working copy), the
  fallback fill along the site's chain on every delivery path, and that a
  site which opts nothing in sees nothing change.

  The test config runs `en` (the default), `fr` and `es`, with no site chain:
  `fr → en`, `es → en`.

  `async: false`, as `KilnCMSWeb.FieldLocalizationDeliveryTest` is: the chain
  is read through the default org's cached `locale_fallbacks` key, which every
  other default-org delivery test shares. Cachex coalesces concurrent misses on
  one key, so an async run can be handed another test's lookup, run in that
  test's sandbox. A failed lookup is not cached and answers every coalesced
  caller `nil`, which `KilnCMS.OrgSettings.resolve/2` turns into the degraded
  chain `[locale]`: nothing to inherit from, and a fallback field reads back
  `nil` (seen once on CI as `"caption" => nil`).
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations
  alias KilnCMS.Firing.Engine
  alias KilnCMS.FixturePlugin.ProductCardBlock
  alias KilnCMS.I18n.FieldFallback
  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMS.I18n.SharedFields
  alias KilnCMS.I18n.SharedFieldsWorker

  # The chain is cached per org and one test here saves the default org's;
  # leave no cached chain behind for whatever runs next.
  setup do
    on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(KilnCMS.Accounts.default_org_id()) end)
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "floc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "floc-#{System.unique_integer([:positive])}"

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

  defp run_worker(record) do
    SharedFieldsWorker.perform(%Oban.Job{
      args: %{"org_id" => record.org_id, "type" => "page", "id" => record.id}
    })
  end

  defp sync_jobs_for(record) do
    worker = inspect(SharedFieldsWorker)

    KilnCMS.Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^worker and fragment("?->>'id'", j.args) == ^record.id
      )
    )
  end

  # An English source and a French translation of it (same slug, same block
  # ids), both published.
  defp document(actor, attrs) do
    en =
      CMS.create_page!(
        Map.merge(%{title: "Product", slug: slug(), locale: "en"}, attrs),
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)
    fr = CMS.publish_page!(fr, %{}, actor: actor)
    {reload(en), reload(fr)}
  end

  describe "declarations" do
    test "a block field declares its mode; an undeclared one is :localized" do
      assert Kiln.Block.Info.localization(ProductCardBlock) == [
               name: :localized,
               image_url: :shared,
               price: :shared,
               caption: :fallback
             ]

      assert FieldLocalization.block_fields(ProductCardBlock) == %{
               image_url: :shared,
               price: :shared,
               caption: :fallback
             }

      # `translatable:` keeps its own, separate meaning (#502).
      assert {:caption, :text} in Kiln.Block.Info.translatable(ProductCardBlock)

      refute Enum.any?(
               Kiln.Block.Info.translatable(ProductCardBlock),
               &(elem(&1, 0) == :image_url)
             )
    end

    test "a field definition is :localized unless it says otherwise" do
      actor = admin()

      plain =
        CMS.create_field_definition!(%{content_type: :page, name: "plain", label: "P"},
          actor: actor
        )

      assert plain.localization == :localized
      assert field(actor, "shared_one", :shared).localization == :shared

      assert {:error, _} =
               CMS.create_field_definition(
                 %{content_type: :page, name: "bad", label: "B", localization: :everywhere},
                 actor: actor
               )
    end

    test "the content option is validated at build time" do
      assert FieldLocalization.validate!(nil, false) == %{shared: [], fallback: []}

      assert FieldLocalization.validate!([shared: [:seo_image], fallback: [:excerpt]], true) ==
               %{shared: [:seo_image], fallback: [:excerpt]}

      assert_raise ArgumentError, ~r/cannot name \[:title\]/, fn ->
        FieldLocalization.validate!([shared: [:title]], false)
      end

      assert_raise ArgumentError, ~r/no excerpt/, fn ->
        FieldLocalization.validate!([fallback: [:excerpt]], false)
      end

      assert_raise ArgumentError, ~r/both shared and fallback/, fn ->
        FieldLocalization.validate!([shared: [:seo_title], fallback: [:seo_title]], false)
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        FieldLocalization.validate!([everywhere: [:seo_title]], false)
      end
    end

    test "the core types opt nothing in" do
      for resource <- [CMS.Page, CMS.Post, CMS.Entry] do
        assert resource.__kiln_localization__() == %{shared: [], fallback: []}
      end
    end
  end

  describe "opt-in, default off" do
    test "a type with nothing declared queues no sync, and fires no inherited_fields" do
      actor = admin()
      {en, fr} = document(actor, %{blocks: [%{"_type" => "heading", "text" => "Hi"}]})

      CMS.update_page!(en, %{title: "Product v2"}, actor: actor)
      assert sync_jobs_for(en) == []

      {:ok, %{json: json}} = Engine.fire(reload(fr), mode: :preview)
      refute Map.has_key?(json, "inherited_fields")
      assert FieldFallback.fill(reload(fr)) == {reload(fr), %{}}
    end
  end

  describe "shared values" do
    test "a shared custom field follows the source when it changes live" do
      actor = admin()
      price = field(actor, "price", :shared)
      note = field(actor, "note", :localized)

      {en, fr} = document(actor, %{custom_fields: %{price.name => "10", note.name => "Hello"}})
      CMS.update_page!(fr, %{custom_fields: %{note.name => "Bonjour"}}, actor: actor)

      en = CMS.update_page!(reload(en), %{custom_fields: %{price.name => "20"}}, actor: actor)
      assert [_job] = sync_jobs_for(en)
      assert :ok = run_worker(en)

      fr = reload(fr)
      assert fr.custom_fields == %{price.name => "20", note.name => "Bonjour"}

      # The copy is a versioned write, so the sync API reports the sibling.
      versions =
        CMS.Page.Version
        |> Ash.Query.filter(version_source_id == ^fr.id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(versions, &(&1.version_action_name == :sync_shared_fields))
    end

    test "a shared block field is copied by block id, and the localized ones are left alone" do
      actor = admin()
      {en, fr} = document(actor, %{blocks: [card(%{})]})

      fr_card = card_of(fr)

      CMS.update_page!(
        reload(fr),
        %{blocks: [card(%{"_id" => fr_card.id, "name" => "Chaussure", "image_url" => "fr.png"})]},
        actor: actor
      )

      en_card = card_of(en)

      en =
        CMS.update_page!(
          reload(en),
          %{blocks: [card(%{"_id" => en_card.id, "image_url" => "new.png", "price" => 12})]},
          actor: actor
        )

      assert :ok = run_worker(en)

      synced = card_of(fr)
      assert synced.id == fr_card.id
      assert synced.name == "Chaussure"
      assert synced.image_url == "new.png"
      assert synced.price == 12
    end

    test "a translation that publishes later takes the source's current values" do
      actor = admin()
      price = field(actor, "price", :shared)

      en =
        CMS.create_page!(
          %{title: "P", slug: slug(), locale: "en", custom_fields: %{price.name => "10"}},
          actor: actor
        )

      en = CMS.publish_page!(en, %{}, actor: actor)
      fr = Translations.create_translation!(:page, en, "fr", actor: actor)
      CMS.update_page!(reload(en), %{custom_fields: %{price.name => "30"}}, actor: actor)
      assert reload(fr).custom_fields[price.name] == "10"

      fr = CMS.publish_page!(reload(fr), %{}, actor: actor)
      assert :ok = run_worker(fr)
      assert reload(fr).custom_fields[price.name] == "30"
    end

    test "a source that is not published shares nothing" do
      actor = admin()
      price = field(actor, "price", :shared)

      en =
        CMS.create_page!(
          %{title: "P", slug: slug(), locale: "en", custom_fields: %{price.name => "10"}},
          actor: actor
        )

      fr = Translations.create_translation!(:page, en, "fr", actor: actor)
      fr = CMS.publish_page!(fr, %{}, actor: actor)
      CMS.update_page!(reload(en), %{custom_fields: %{price.name => "99"}}, actor: actor)

      assert :ok = run_worker(fr)
      assert reload(fr).custom_fields[price.name] == "10"
    end

    test "a sibling's pending working copy gets the value too, and publishes without a conflict" do
      actor = admin()
      {en, fr} = document(actor, %{blocks: [card(%{})]})
      fr_card = card_of(fr)

      # The translator is mid-edit on the live French page.
      {:ok, _fr} =
        CMS.save_page_working_copy(
          reload(fr),
          %{
            working_title: fr.title,
            working_blocks: [card(%{"_id" => fr_card.id, "name" => "Chaussure"})]
          },
          actor: actor,
          tenant: fr.org_id
        )

      en_card = card_of(en)

      en =
        CMS.update_page!(
          reload(en),
          %{blocks: [card(%{"_id" => en_card.id, "image_url" => "new.png"})]},
          actor: actor
        )

      assert :ok = run_worker(en)

      fr = reload(fr)
      assert KilnCMS.CMS.WorkingCopy.pending?(fr)
      [%Ash.Union{value: live}] = fr.blocks
      [%Ash.Union{value: held}] = fr.working_blocks
      assert live.image_url == "new.png"
      assert held.image_url == "new.png"
      assert held.name == "Chaussure"

      # The shared copy is not a conflict with the translator's draft.
      assert KilnCMS.CMS.WorkingCopy.reconcile(fr).conflicts == []

      published = CMS.publish_page_changes!(fr, %{}, actor: actor, tenant: fr.org_id)
      [%Ash.Union{value: out}] = published.blocks
      assert out.name == "Chaussure"
      assert out.image_url == "new.png"
    end

    test "the source's unpublished working copy is held until Publish changes" do
      actor = admin()
      price = field(actor, "price", :shared)
      {en, fr} = document(actor, %{custom_fields: %{price.name => "10"}})

      {:ok, en} =
        CMS.save_page_working_copy(
          reload(en),
          %{working_title: en.title, fields: %{"custom_fields" => %{price.name => "50"}}},
          actor: actor,
          tenant: en.org_id
        )

      assert :ok = run_worker(en)
      assert reload(fr).custom_fields[price.name] == "10"

      en = CMS.publish_page_changes!(reload(en), %{}, actor: actor, tenant: en.org_id)
      assert reload(en).custom_fields[price.name] == "50"
      assert :ok = run_worker(en)
      assert reload(fr).custom_fields[price.name] == "50"
    end

    test "shared record attributes are planned from the type's modes" do
      actor = admin()
      {en, fr} = document(actor, %{seo_image: "https://example.com/a.png", seo_title: "EN"})
      en = %{en | seo_image: "https://example.com/b.png", seo_title: "EN v2"}

      assert SharedFields.plan(en, fr, [], %{shared: [:seo_image], fallback: []}) ==
               %{seo_image: "https://example.com/b.png"}

      assert SharedFields.plan(en, fr, []) == %{}
    end
  end

  describe "fallback values" do
    test "an empty fallback custom field inherits along the chain, on every surface" do
      actor = admin()
      tagline = field(actor, "tagline", :fallback)
      {en, fr} = document(actor, %{custom_fields: %{tagline.name => "Made by hand"}})
      fr = CMS.update_page!(reload(fr), %{custom_fields: %{tagline.name => ""}}, actor: actor)

      assert {filled, %{"custom_fields" => %{"tagline" => "en"}}} = FieldFallback.fill(fr)
      assert filled.custom_fields[tagline.name] == "Made by hand"
      # Nothing is written back.
      assert reload(fr).custom_fields[tagline.name] in [nil, ""]

      {:ok, %{json: json}} = Engine.fire(reload(fr), mode: :preview)
      assert json["custom_fields"][tagline.name] == "Made by hand"
      assert json["inherited_fields"] == %{"custom_fields" => %{"tagline" => "en"}}

      loaded =
        CMS.get_page!(fr.id, load: [:inherited_fields], authorize?: false, tenant: fr.org_id)

      assert loaded.inherited_fields == %{
               "custom_fields" => %{
                 "tagline" => %{"value" => "Made by hand", "locale" => "en"}
               }
             }

      # A variant with its own value keeps it.
      {_en, en_inherited} = FieldFallback.fill(reload(en))
      assert en_inherited == %{}
    end

    test "an empty fallback block field inherits from the block with the same id" do
      actor = admin()
      {_en, fr} = document(actor, %{blocks: [card(%{"caption" => "Waterproof"})]})
      fr_card = card_of(fr)

      CMS.update_page!(
        reload(fr),
        %{blocks: [card(%{"_id" => fr_card.id, "name" => "Chaussure", "caption" => ""})]},
        actor: actor
      )

      {:ok, %{json: json, web: web}} = Engine.fire(reload(fr), mode: :preview)
      assert [%{"name" => "Chaussure", "caption" => "Waterproof"}] = json["blocks"]
      assert json["inherited_fields"] == %{"blocks" => %{fr_card.id => %{"caption" => "en"}}}
      assert web["html"] =~ "Waterproof"
    end

    test "only a published, public-enough, unlocked sibling is inherited from" do
      actor = admin()
      tagline = field(actor, "tagline", :fallback)

      en =
        CMS.create_page!(
          %{
            title: "P",
            slug: slug(),
            locale: "en",
            custom_fields: %{tagline.name => "Draft text"}
          },
          actor: actor
        )

      fr = Translations.create_translation!(:page, en, "fr", actor: actor)
      fr = CMS.update_page!(fr, %{custom_fields: %{tagline.name => ""}}, actor: actor)
      fr = CMS.publish_page!(fr, %{}, actor: actor)

      # The source is a draft.
      assert {_fr, %{}} = FieldFallback.fill(reload(fr))

      # Published, but for members only: a public page may not carry its text.
      en = CMS.update_page!(reload(en), %{audience: :member}, actor: actor)
      CMS.publish_page!(en, %{}, actor: actor)
      assert {_fr, %{}} = FieldFallback.fill(reload(fr))
    end

    test "fallback record attributes are filled from the type's modes" do
      actor = admin()
      {_en, fr} = document(actor, %{seo_description: "English description"})
      fr = CMS.update_page!(reload(fr), %{seo_description: nil}, actor: actor)

      assert {filled, %{"seo_description" => "en"}} =
               FieldFallback.fill(fr, attributes: %{shared: [], fallback: [:seo_description]})

      assert filled.seo_description == "English description"
      assert {_same, %{}} = FieldFallback.fill(fr)
    end

    test "a point-in-time fire does not inherit" do
      actor = admin()
      tagline = field(actor, "tagline", :fallback)
      {_en, fr} = document(actor, %{custom_fields: %{tagline.name => "Made by hand"}})
      fr = CMS.update_page!(reload(fr), %{custom_fields: %{tagline.name => ""}}, actor: actor)

      {:ok, %{json: json}} = Engine.fire(fr, mode: :preview, custom_fields: :as_stored)
      refute Map.has_key?(json, "inherited_fields")
    end

    test "a publish of the source re-fires the published siblings" do
      actor = admin()
      tagline = field(actor, "tagline", :fallback)
      {en, fr} = document(actor, %{custom_fields: %{tagline.name => "One"}})
      CMS.update_page!(reload(fr), %{custom_fields: %{tagline.name => ""}}, actor: actor)
      KilnCMS.DataCase.drain_oban()

      CMS.update_page!(reload(en), %{custom_fields: %{tagline.name => "Two"}}, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, body} = Engine.read(fr.org_id, :page, fr.id, :json)
      assert body["custom_fields"][tagline.name] == "Two"
      assert body["inherited_fields"] == %{"custom_fields" => %{"tagline" => "en"}}
    end
  end

  describe "the translation workflow around it" do
    test "a shared-value copy does not make an outdated translation look fresh" do
      actor = admin()
      price = field(actor, "price", :shared)
      {en, fr} = document(actor, %{custom_fields: %{price.name => "10"}})

      en =
        CMS.update_page!(reload(en), %{title: "Product v2", custom_fields: %{price.name => "20"}},
          actor: actor
        )

      assert stale?(en, "fr", actor)

      assert :ok = run_worker(en)
      assert reload(fr).custom_fields[price.name] == "20"
      assert DateTime.after?(reload(fr).updated_at, reload(en).updated_at)
      assert stale?(en, "fr", actor), "the copy is not a translator's edit"

      CMS.update_page!(reload(fr), %{title: "Produit v2"}, actor: actor)
      refute stale?(reload(en), "fr", actor)
    end

    test "XLIFF leaves shared block fields out of the file, both ways" do
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "P", slug: slug(), locale: "en", blocks: [card(%{"caption" => "Soft"})]},
          actor: actor
        )

      {units, _warnings} = KilnCMS.CMS.Xliff.Units.extract(reload(page))
      fields = units |> Enum.map(& &1.id) |> Enum.map(&List.last(String.split(&1, ".")))

      assert "name" in fields
      assert "caption" in fields
      refute "image_url" in fields
    end

    test "the schema export annotates the modes, and declares inherited_fields" do
      actor = admin()
      field(actor, "tagline", :fallback)
      field(actor, "plain_note", :localized)

      schema = KilnCMS.SchemaExport.json_schema()
      card_schema = schema["$defs"]["block_product_card"]

      assert card_schema["properties"]["image_url"]["x-kiln-localization"] == "shared"
      assert card_schema["properties"]["caption"]["x-kiln-localization"] == "fallback"
      refute Map.has_key?(card_schema["properties"]["name"], "x-kiln-localization")

      page_schema = schema["$defs"]["content_page"]
      custom = page_schema["properties"]["custom_fields"]["properties"]
      assert custom["tagline"]["x-kiln-localization"] == "fallback"
      refute Map.has_key?(custom["plain_note"], "x-kiln-localization")
      assert Map.has_key?(page_schema["properties"], "inherited_fields")
      refute "inherited_fields" in page_schema["required"]
    end

    test "saving the fallback chain re-fires the translations that can inherit" do
      actor = admin()
      {en, fr} = document(actor, %{blocks: [card(%{"caption" => "Soft"})]})
      KilnCMS.DataCase.drain_oban()
      KilnCMS.Repo.delete_all(Oban.Job)

      CMS.save_site_locale_settings!(%{fallbacks: %{"fr" => []}},
        authorize?: false,
        tenant: fr.org_id
      )

      refire = inspect(KilnCMS.I18n.RefireInheritingWorker)
      fire = inspect(KilnCMS.Firing.FireWorker)

      assert [_job] =
               KilnCMS.Repo.all(
                 from(j in Oban.Job, where: j.worker == ^refire and j.state == "available")
               )

      assert %{failure: 0} = KilnCMS.DataCase.drain_oban()

      fired_ids =
        KilnCMS.Repo.all(
          from(j in Oban.Job, where: j.worker == ^fire, select: fragment("?->>'id'", j.args))
        )

      assert fr.id in fired_ids
      refute en.id in fired_ids
    end
  end

  defp stale?(source, locale, actor) do
    source
    |> then(&Translations.coverage(:page, &1, actor: actor))
    |> Enum.find(&(&1.locale == locale))
    |> Map.fetch!(:stale?)
  end
end
