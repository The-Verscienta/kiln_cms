defmodule KilnCMS.SchemaExport.SwiftUIReaderFixture do
  @moduledoc """
  The state behind the SwiftUI reader example's checked-in models,
  `examples/swiftui-reader/Sources/KilnModels/Kiln.swift` (#2579), shared by
  the test that writes them (`KilnCMS.SchemaExport.RegenerateSwiftUIReaderTest`)
  and the one that fails when they are stale
  (`KilnCMS.SchemaExport.SwiftUIReaderDriftTest`).

  The example reads one admin-defined type, `recipe`. Its definition lives in
  `examples/swiftui-reader/kiln/recipe_type.exs`, which the demo seed
  (`kiln/seed.exs`) evaluates too, so the models describe exactly what the
  seed creates. The export carries only the core blocks
  (`KilnCMS.Blocks.core_modules/0`): the test env compiles fixture plugins in,
  and the example must not describe them.

  Needs a sandboxed repo (`KilnCMS.DataCase`, not async: the dynamic-type
  registry reads across the table).
  """

  alias KilnCMS.CMS
  alias KilnCMS.SchemaExport

  @example Path.expand("../../examples/swiftui-reader", __DIR__)

  @regenerate_command "mix test --only regenerate_swiftui_models " <>
                        "test/kiln_cms/schema_export/regenerate_swiftui_reader_test.exs"

  @doc "Where the example's generated models are checked in."
  @spec models_path() :: Path.t()
  def models_path, do: Path.join(@example, "Sources/KilnModels/Kiln.swift")

  @doc "The command that rewrites the models, for failure messages."
  @spec regenerate_command() :: String.t()
  def regenerate_command, do: @regenerate_command

  @doc "The `recipe` type definition shared with the demo seed."
  @spec recipe_type() :: %{type: map(), fields: [map()]}
  def recipe_type do
    {definition, _binding} = Code.eval_file(Path.join(@example, "kiln/recipe_type.exs"))
    definition
  end

  @doc "Create the `recipe` type and its fields in the default org."
  @spec setup!() :: :ok
  def setup! do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "swiftui-reader-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    opts = [actor: actor, tenant: KilnCMS.Accounts.default_org_id()]
    %{type: type, fields: fields} = recipe_type()
    recipe = CMS.create_type_definition!(type, opts)

    for field <- fields do
      {sub_fields, attrs} = Map.pop(field, :fields, [])
      created = CMS.create_field_definition!(Map.put(attrs, :type_definition_id, recipe.id), opts)

      for sub <- sub_fields,
          do: CMS.create_field_definition!(Map.put(sub, :group_of_id, created.id), opts)
    end

    :ok
  end

  @doc "The Swift models the example checks in, generated from the live export."
  @spec swift() :: String.t()
  def swift do
    [
      org_id: KilnCMS.Accounts.default_org_id(),
      types: ["recipe"],
      blocks: KilnCMS.Blocks.core_modules()
    ]
    |> SchemaExport.json_schema()
    |> SchemaExport.Swift.emit()
  end
end
