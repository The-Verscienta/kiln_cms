defmodule KilnCMS.I18n.BlockFieldsConfigTest do
  @moduledoc """
  A site opts a **core** block's fields into `:shared` / `:fallback` through
  `config :kiln_cms, :i18n, block_fields: %{"image" => [...]}` (#2270), since
  a core block declares nothing itself. `FieldLocalization.block_fields/1` is
  the one reader, so these cover the fold itself and then one consumer each:
  the shared copy, the fallback fill, the write refusal (#1860), XLIFF, and a
  block nested inside `columns`.

  `async: false`: the case sets `:i18n` application env, which is VM-global,
  and the fallback chain is read through the default org's cached key, which
  every other default-org delivery test shares (see
  `KilnCMS.I18n.FieldLocalizationTest`).
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Blocks.Image
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations
  alias KilnCMS.Firing.Engine
  alias KilnCMS.FixturePlugin.ProductCardBlock
  alias KilnCMS.I18n.FieldFallback
  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMS.I18n.SharedFieldsWorker

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

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bfc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "bfc-#{System.unique_integer([:positive])}"

  defp image(attrs) do
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

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp image_of(page) do
    [%Ash.Union{type: :image, value: image}] = reload(page).blocks
    image
  end

  defp columns(children, attrs \\ %{}),
    do: Map.merge(%{"_type" => "columns", "columns" => [%{"blocks" => children}]}, attrs)

  defp nested_image(attrs), do: image(Map.put_new(attrs, "id", Ash.UUID.generate()))

  defp nested_of(page) do
    [%Ash.Union{type: :columns, value: cols}] = reload(page).blocks
    [%{"blocks" => [child]}] = cols.columns
    {cols, child}
  end

  defp run_worker(record) do
    SharedFieldsWorker.perform(%Oban.Job{
      args: %{"org_id" => record.org_id, "type" => "page", "id" => record.id}
    })
  end

  # An English source and a French translation of it, both published.
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

  describe "the fold in block_fields/1" do
    test "a core block declares nothing, and configures nothing by default" do
      assert Kiln.Block.Info.localization(Image) == [
               url: :localized,
               alt: :localized,
               caption: :localized,
               media_id: :localized
             ]

      assert FieldLocalization.block_fields(Image) == %{}
    end

    test "config alone opts a core block in", ctx do
      configure(ctx, %{"image" => [shared: [:url, :media_id], fallback: [:alt]]})

      assert FieldLocalization.block_fields(Image) ==
               %{url: :shared, media_id: :shared, alt: :fallback}

      # Other blocks are untouched.
      assert FieldLocalization.block_fields(KilnCMS.Blocks.Heading) == %{}
    end

    test "config joins what the block declares", ctx do
      # product_card declares image_url, price, in_stock :shared and caption
      # :fallback, and leaves name :localized.
      configure(ctx, %{
        "product_card" => [shared: [:name, :caption], fallback: [:image_url]]
      })

      modes = FieldLocalization.block_fields(ProductCardBlock)

      # Declared shared beats a configured fallback.
      assert modes.image_url == :shared
      # Declared fallback loses to nothing but declared shared: a configured
      # shared does not take it over.
      assert modes.caption == :fallback
      # Configured on an undeclared field.
      assert modes.name == :shared
      # Declared and not mentioned: unchanged.
      assert modes.price == :shared
      assert modes.in_stock == :shared
    end

    test "a configured fallback beats a declared-localized field's shared, and not a declared shared",
         ctx do
      # Both directions of `merge/2` through `block_fields/1`: a name in two
      # sources resolves to fallback unless the block declared it shared.
      configure(ctx, %{"product_card" => [fallback: [:name, :price]]})
      modes = FieldLocalization.block_fields(ProductCardBlock)
      assert modes.name == :fallback
      assert modes.price == :shared

      configure(ctx, %{"product_card" => [shared: [:caption]]})
      assert FieldLocalization.block_fields(ProductCardBlock).caption == :fallback
    end

    test "malformed and unknown entries are ignored, once per config, not per call", ctx do
      marker = "nope_#{System.unique_integer([:positive])}"

      configure(ctx, %{
        marker => [shared: [:url]],
        "gallery" => [shared: [:items]],
        "heading" => [shared: [:bogus]],
        "quote" => [shared: [:text], fallback: [:text]],
        "video" => :garbage,
        "audio" => [shared: "url"],
        "embed" => [sharedd: [:url]],
        # The valid entry still applies.
        "image" => [fallback: [:alt]]
      })

      log =
        capture_log(fn ->
          for _call <- 1..5 do
            assert FieldLocalization.block_fields(Image) == %{alt: :fallback}
            assert FieldLocalization.block_fields(KilnCMS.Blocks.Heading) == %{}
            assert FieldLocalization.block_fields(KilnCMS.Blocks.Quote) == %{}
          end
        end)

      for fragment <- [
            "#{inspect(marker)}: no such block type",
            "\"gallery\": the gallery block cannot be localized per field",
            "\"heading\": `shared:` names [:bogus]",
            "\"quote\": [:text] cannot be both shared and fallback",
            "\"video\": expected a keyword list",
            "\"audio\": `shared:` must be a list of field names",
            "\"embed\": expected a keyword list"
          ] do
        assert count(log, fragment) == 1, "expected #{fragment} once in:\n#{log}"
      end
    end

    test "a config that is not a map is ignored with one warning", ctx do
      configure(ctx, [{"image", "oops_#{System.unique_integer([:positive])}"}])

      log =
        capture_log(fn ->
          for _call <- 1..3, do: assert(FieldLocalization.block_fields(Image) == %{})
        end)

      assert count(log, "ignoring :i18n block_fields: expected a map") == 1
    end

    test "removing the config restores the declared behaviour", ctx do
      configure(ctx, %{"image" => [shared: [:url]]})
      assert FieldLocalization.block_fields(Image) == %{url: :shared}

      Application.put_env(:kiln_cms, :i18n, ctx.previous)
      assert FieldLocalization.block_fields(Image) == %{}

      assert FieldLocalization.block_fields(ProductCardBlock) == %{
               image_url: :shared,
               price: :shared,
               caption: :fallback,
               in_stock: :shared
             }
    end
  end

  describe "consumers see the configured modes" do
    test "the shared copy reaches a top-level image", ctx do
      configure(ctx, %{"image" => [shared: [:url]]})
      actor = user(:admin)
      {en, fr} = document(actor, %{blocks: [image(%{})]})
      fr_image = image_of(fr)

      # A translation holding its own value for the shared field, seeded past
      # the write refusal for the copy to overwrite.
      [%Ash.Union{value: held} = union] = fr.blocks

      Ash.Seed.update!(fr, %{
        blocks: [%{union | value: %{held | url: "https://example.com/fr.png"}}]
      })

      assert image_of(fr).url == "https://example.com/fr.png"

      en_image = image_of(en)

      en =
        CMS.update_page!(
          reload(en),
          %{
            blocks: [
              image(%{
                "_id" => en_image.id,
                "url" => "https://example.com/new.png",
                "alt" => "New"
              })
            ]
          },
          actor: actor
        )

      assert :ok = run_worker(en)

      synced = image_of(fr)
      assert synced.id == fr_image.id
      assert synced.url == "https://example.com/new.png"
      # Not configured: the translation keeps its own.
      assert synced.alt == "A shoe"
    end

    test "the shared copy reaches an image nested in columns", ctx do
      configure(ctx, %{"image" => [shared: [:url]]})
      actor = user(:admin)
      {en, fr} = document(actor, %{blocks: [columns([nested_image(%{})])]})
      {fr_cols, fr_child} = nested_of(fr)
      {en_cols, en_child} = nested_of(en)
      assert fr_child["id"] == en_child["id"]

      held = Map.put(fr_child, "url", "https://example.com/fr.png")
      [union] = reload(fr).blocks

      Ash.Seed.update!(reload(fr), %{
        blocks: [%{union | value: %{fr_cols | columns: [%{"blocks" => [held]}]}}]
      })

      en =
        CMS.update_page!(
          reload(en),
          %{
            blocks: [
              columns(
                [image(%{"id" => en_child["id"], "url" => "https://example.com/new.png"})],
                %{
                  "_id" => en_cols.id
                }
              )
            ]
          },
          actor: actor
        )

      assert :ok = run_worker(en)

      {_cols, synced} = nested_of(fr)
      assert synced["url"] == "https://example.com/new.png"
    end

    test "an empty fallback field is filled from the source, top level and nested", ctx do
      configure(ctx, %{"image" => [fallback: [:alt]]})
      actor = user(:admin)
      {_en, fr} = document(actor, %{blocks: [image(%{"alt" => "A shoe"})]})
      fr_image = image_of(fr)

      CMS.update_page!(
        reload(fr),
        %{blocks: [image(%{"_id" => fr_image.id, "alt" => "", "caption" => "Cuir"})]},
        actor: actor
      )

      {:ok, %{json: json}} = Engine.fire(reload(fr), mode: :preview)
      assert [%{"alt" => "A shoe", "caption" => "Cuir"}] = json["blocks"]
      assert json["inherited_fields"] == %{"blocks" => %{fr_image.id => %{"alt" => "en"}}}

      {_en, fr} =
        document(actor, %{blocks: [columns([nested_image(%{"alt" => "Nested shoe"})])]})

      {fr_cols, fr_child} = nested_of(fr)

      CMS.update_page!(
        reload(fr),
        %{blocks: [columns([Map.put(fr_child, "alt", "")], %{"_id" => fr_cols.id})]},
        actor: actor
      )

      {filled, inherited} = FieldFallback.fill(reload(fr))
      assert inherited == %{"blocks" => %{fr_child["id"] => %{"alt" => "en"}}}
      [%Ash.Union{value: %{columns: [%{"blocks" => [child]}]}}] = filled.blocks
      assert child["alt"] == "Nested shoe"
    end

    test "a write to a shared image field on a translation is refused, and only then", ctx do
      configure(ctx, %{"image" => [shared: [:url]]})
      admin = user(:admin)
      editor = user(:editor)
      {_en, fr} = document(admin, %{blocks: [image(%{})]})
      fr_image = image_of(fr)

      write = fn actor, attrs ->
        CMS.update_page(reload(fr), %{blocks: [image(Map.put(attrs, "_id", fr_image.id))]},
          actor: actor
        )
      end

      for actor <- [admin, editor] do
        assert {:error, %Ash.Error.Invalid{errors: [error]}} =
                 write.(actor, %{"url" => "https://example.com/fr.png"})

        assert %Ash.Error.Changes.InvalidAttribute{field: :blocks} = error
        assert Exception.message(error) =~ "image.url"
        assert Exception.message(error) =~ fr_image.id
      end

      # A field the config leaves localized, and a re-send of the shared one.
      assert {:ok, updated} = write.(editor, %{"alt" => "Une chaussure"})

      assert [%Ash.Union{value: %{alt: "Une chaussure", url: "https://example.com/en.png"}}] =
               updated.blocks

      # Removing the config restores editability (the e2e toggle's contract).
      Application.put_env(:kiln_cms, :i18n, ctx.previous)
      assert {:ok, updated} = write.(editor, %{"url" => "https://example.com/fr.png"})
      assert [%Ash.Union{value: %{url: "https://example.com/fr.png"}}] = updated.blocks
    end

    test "XLIFF leaves a shared image field out of the file", ctx do
      configure(ctx, %{"image" => [shared: [:alt]]})
      actor = user(:admin)

      page =
        CMS.create_page!(
          %{title: "P", slug: slug(), locale: "en", blocks: [image(%{})]},
          actor: actor
        )

      {units, _warnings} = KilnCMS.CMS.Xliff.Units.extract(reload(page))
      fields = units |> Enum.map(& &1.id) |> Enum.map(&List.last(String.split(&1, ".")))

      assert "caption" in fields
      refute "alt" in fields

      Application.put_env(:kiln_cms, :i18n, ctx.previous)
      {units, _warnings} = KilnCMS.CMS.Xliff.Units.extract(reload(page))
      assert "alt" in Enum.map(units, &List.last(String.split(&1.id, ".")))
    end
  end

  defp count(log, fragment), do: length(String.split(log, fragment)) - 1
end
