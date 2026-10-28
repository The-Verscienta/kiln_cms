defmodule KilnCMS.SchemaExport.RegenerateGoldensTest do
  @moduledoc """
  Rewrites the full-schema fixture and the emitter goldens under
  `test/support/fixtures/schema_export/` — **not a test**, and excluded from
  every run (`:regenerate_schema_goldens` in `test_helper.exs`).

  The fixture is a real `KilnCMS.SchemaExport.json_schema/1` export: every
  registered block plus `post` and `page`, with a `post` custom field of each
  kind (both `:text` formats with `deliver_plain`, single and multiple
  `:select`/`:media`/`:reference`, a single and a repeating `:group`, a
  `Kiln.FieldType`). Checked in rather than built per run, so the goldens
  change only when someone regenerates them and the diff shows what moved.

  After a deliberate change to the export or an emitter:

      mix test --only regenerate_schema_goldens test/kiln_cms/schema_export/regenerate_goldens_test.exs

  then review the diff of `full.schema.json`, `full.d.ts` and `full.swift`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.SchemaExport

  @dir Path.expand("../../support/fixtures/schema_export", __DIR__)

  @fields [
    {"subtitle", :string, %{}},
    {"summary", :text, %{deliver_plain: true}},
    {"code_sample", :text, %{format: :plain}},
    {"read_time", :integer, %{}},
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
    {"where", :geolocation, %{}}
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

    document =
      SchemaExport.json_schema(
        org_id: KilnCMS.Accounts.default_org_id(),
        types: ["post", "page"]
      )

    # Through the task's own sorted encoder, so the fixture diffs stably.
    File.write!(
      Path.join(@dir, "full.schema.json"),
      Mix.Tasks.Kiln.Export.Schema.encode(document, :json, true)
    )

    File.write!(Path.join(@dir, "full.d.ts"), SchemaExport.TypeScript.emit(document))
    File.write!(Path.join(@dir, "full.swift"), SchemaExport.Swift.emit(document))
  end
end
