defmodule KilnCMS.SchemaExport.RegenerateGoldensTest do
  @moduledoc """
  Rewrites the full-schema fixture and the emitter goldens under
  `test/support/fixtures/schema_export/` — **not a test**, and excluded from
  every run (`:regenerate_schema_goldens` in `test_helper.exs`).

  The fixture is a real `KilnCMS.SchemaExport.json_schema/1` export: every
  registered block plus `post` and `page`, with a `post` custom field of each
  kind (a `:string` list, typed lists of dates, integers and emails, both `:text` formats with `deliver_plain`, single and multiple
  `:select`/`:media`/`:reference`, a single and a repeating `:group`, a
  `Kiln.FieldType`), two of them in a tab section at less than full width. Checked in rather than built per run, so the goldens
  change only when someone regenerates them and the diff shows what moved.

  After a deliberate change to the export or an emitter:

      mix test --only regenerate_schema_goldens test/kiln_cms/schema_export/regenerate_goldens_test.exs

  then review the diff of `full.schema.json`, `full.graphql.schema.json`, `full.graphql.ts`, `full.graphql.swift`, `full.graphql.kt`, `full.d.ts`, `full.swift` and `full.kt`.
  `clients/js/test/parity.test.ts` reads `full.d.ts` too. Run `npm test` in
  `clients/js` as well; if a change to the TypeScript emitter isn't mirrored
  in `kiln-types`, that run fails.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.SchemaExport

  @dir Path.expand("../../support/fixtures/schema_export", __DIR__)

  @fields [
    {"subtitle", :string, %{section: "Overview", width: :half}},
    {"synonyms", :string, %{multiple: true}},
    {"summary", :text, %{deliver_plain: true}},
    {"code_sample", :text, %{format: :plain}},
    {"read_time", :integer, %{section: "Overview", width: :third}},
    {"rating", :float, %{}},
    {"featured", :boolean, %{}},
    {"launch_date", :date, %{}},
    {"published_at", :datetime, %{}},
    {"homepage", :url, %{}},
    {"tier", :select, %{options: ["free", "pro"]}},
    {"properties", :select,
     %{options: ["tonic", "bitter"], multiple: true, allow_custom: true, max_items: 5}},
    {"hero", :media, %{}},
    {"gallery", :media, %{multiple: true}},
    {"related", :reference, %{target_type: "post", multiple: true}},
    {"parent", :reference, %{target_type: "post"}},
    {"where", :geolocation, %{}},
    {"contact_email", :email, %{}},
    {"phone", :telephone, %{}},
    {"accent", :color, %{}},
    {"handle", :slug, %{}},
    {"opens_at", :time, %{}},
    {"extra", :json, %{}},
    {"price_band", :range, %{}},
    {"specs", :key_value, %{}},
    {"source", :link, %{}},
    {"event_dates", :date, %{multiple: true, max_items: 10}},
    {"scores", :integer, %{multiple: true, min_items: 1}},
    {"contacts", :email, %{multiple: true}}
  ]

  @tag :regenerate_schema_goldens
  test "regenerate the full-schema fixture and its goldens" do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "goldens-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    define = fn attrs -> CMS.create_field_definition!(attrs, actor: actor) end

    for {name, type, extra} <- @fields do
      define.(Map.merge(%{content_type: :post, name: name, label: name, field_type: type}, extra))
    end

    dosages =
      define.(%{
        content_type: :post,
        name: "dosages",
        label: "Dosages",
        field_type: :group,
        multiple: true
      })

    for {name, type, extra} <- [
          {"amount", :float, %{}},
          {"unit", :select, %{options: ["g", "ml"]}},
          {"form", :string, %{}}
        ] do
      define.(
        Map.merge(%{name: name, label: name, field_type: type, group_of_id: dosages.id}, extra)
      )
    end

    seo = define.(%{content_type: :post, name: "seo", label: "SEO", field_type: :group})

    for {name, type} <- [{"title", :string}, {"no_index", :boolean}],
        do: define.(%{name: name, label: name, field_type: type, group_of_id: seo.id})

    # The editor layout annotations (#2280): `x-kiln-width` and
    # `x-kiln-section-display` on the two "Overview" fields.
    CMS.create_field_section!(%{content_type: :post, name: "Overview", display: :tab},
      actor: actor
    )

    document =
      SchemaExport.json_schema(
        org_id: KilnCMS.Accounts.default_org_id(),
        types: ["post", "page"]
      )

    # Through the task's own sorted encoder, so the fixture diffs stably.
    File.write!(
      Path.join(@dir, "full.schema.json"),
      Mix.Tasks.Kiln.Export.Schema.encode(document, :json, pretty: true)
    )

    # The same definitions with the GraphQL annotations (#2290), for the
    # `*-graphql` goldens.
    graphql_document =
      SchemaExport.json_schema(
        org_id: KilnCMS.Accounts.default_org_id(),
        types: ["post", "page"],
        graphql: true
      )

    File.write!(
      Path.join(@dir, "full.graphql.schema.json"),
      Mix.Tasks.Kiln.Export.Schema.encode(graphql_document, :json, pretty: true)
    )

    File.write!(
      Path.join(@dir, "full.graphql.ts"),
      SchemaExport.TypeScript.emit_graphql(graphql_document)
    )

    File.write!(
      Path.join(@dir, "full.graphql.swift"),
      SchemaExport.Swift.emit_graphql(graphql_document)
    )

    File.write!(
      Path.join(@dir, "full.graphql.kt"),
      SchemaExport.Kotlin.emit_graphql(graphql_document)
    )

    File.write!(Path.join(@dir, "full.d.ts"), SchemaExport.TypeScript.emit(document))
    File.write!(Path.join(@dir, "full.swift"), SchemaExport.Swift.emit(document))
    File.write!(Path.join(@dir, "full.kt"), SchemaExport.Kotlin.emit(document))
  end
end
