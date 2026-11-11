defmodule KilnCMS.SchemaExport.GoldenFixture do
  @moduledoc """
  The state behind the full-schema goldens under
  `test/support/fixtures/schema_export/`, shared by the test that writes them
  (`KilnCMS.SchemaExport.RegenerateGoldensTest`) and the one that fails when
  the live export has moved away from them (`KilnCMS.SchemaExport.DriftTest`).

  Every registered block (the core ones and both fixture plugins'), `post` and
  `page`, and one admin-defined type:

    * `post` gets a custom field of each core kind (a `:string` list, typed
      lists of dates, integers and emails, both `:text` formats with
      `deliver_plain`, single and multiple `:select`/`:media`/`:reference`, a
      single and a repeating `:group`), two of them in a tab section at less
      than full width;
    * `review`, a `KilnCMS.CMS.TypeDefinition`, gets the dependency plugin's
      `stars` field type, which declares its own
      `c:Kiln.FieldType.json_schema/1`, and a core `:string` field.

  So the goldens cover all three contribution kinds: plugin blocks, plugin
  field types, and dynamic types.

  Needs a sandboxed repo (`KilnCMS.DataCase`, not async: the dynamic-type
  registry reads across the table).
  """

  alias KilnCMS.CMS
  alias KilnCMS.SchemaExport

  @dir Path.expand("fixtures/schema_export", __DIR__)

  @dynamic_type "review"

  @types ["post", "page", @dynamic_type]

  @regenerate_command "mix test --only regenerate_schema_goldens " <>
                        "test/kiln_cms/schema_export/regenerate_goldens_test.exs"

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

  @doc "The directory the goldens live in."
  @spec dir() :: Path.t()
  def dir, do: @dir

  @doc "The command that rewrites the goldens, for failure messages."
  @spec regenerate_command() :: String.t()
  def regenerate_command, do: @regenerate_command

  @doc "The admin-defined type the fixture adds."
  @spec dynamic_type() :: String.t()
  def dynamic_type, do: @dynamic_type

  @doc """
  Create the custom fields, section and dynamic type the goldens describe, in
  the default org.
  """
  @spec setup!() :: :ok
  def setup! do
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

    # An admin-defined type (#2274) with a plugin field type and a core one.
    org_id = KilnCMS.Accounts.default_org_id()

    review =
      CMS.create_type_definition!(%{name: @dynamic_type, label: "Review"},
        actor: actor,
        tenant: org_id
      )

    for {name, type} <- [{"score", :stars}, {"verdict", :string}] do
      CMS.create_field_definition!(
        %{type_definition_id: review.id, name: name, label: name, field_type: type},
        actor: actor,
        tenant: org_id
      )
    end

    :ok
  end

  @doc "The export the goldens hold: plain, or with the GraphQL annotations (#2290)."
  @spec document(keyword()) :: map()
  def document(opts \\ []) do
    SchemaExport.json_schema(
      org_id: KilnCMS.Accounts.default_org_id(),
      types: @types,
      graphql: Keyword.get(opts, :graphql, false)
    )
  end

  @doc """
  `document` as it is written to disk: through the task's own sorted encoder,
  so the fixture diffs stably.
  """
  @spec encode(map()) :: String.t()
  def encode(document), do: Mix.Tasks.Kiln.Export.Schema.encode(document, :json, pretty: true)
end
