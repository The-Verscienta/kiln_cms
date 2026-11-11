defmodule KilnCMS.SchemaExport.OpenApi do
  @moduledoc """
  The delivery schema as OpenAPI 3.1 components (#2274), for a client
  generator that reads OpenAPI rather than bare JSON Schema.

  A schema object in OpenAPI 3.1 *is* JSON Schema 2020-12, so nothing is
  translated keyword by keyword. What changes is where things live:

    * every `$defs` entry becomes `components.schemas.<name>`, and every
      `$ref` into `#/$defs/` is rewritten to `#/components/schemas/`;
    * the root `oneOf` over the document schemas becomes a `document`
      component tagged by `type` (absent when the export has no documents, as
      with `blocks_only`);
    * `$schema` becomes the document's `jsonSchemaDialect`, and the root `$id`
      is dropped: it names the JSON Schema document at `/api/schema`, which
      this is not;
    * a union tagged by a `discriminator` (the block union on `_type`, and the
      `document` union on `type`) gets an
      explicit `mapping` from each member's tag to its component. JSON Schema
      has no use for it, but an OpenAPI generator otherwise derives the tag
      from the component name (`block_heading`), which is not the `_type`
      value (`heading`) a fired artifact carries.

  `x-kiln` is kept as-is. There are no `paths`: this describes the payloads of
  `GET /api/content/:type/:slug?surface=json`, not the routes (the JSON:API's
  own OpenAPI document at `/api/json/open_api` does that).

  `info.version` is the fired-artifact format version
  (`x-kiln.artifact_format_version`), not the application version: it changes
  when the shape does, so two deployments serving the same shape agree.
  """

  @defs_prefix "#/$defs/"
  @components_prefix "#/components/schemas/"

  @doc """
  The OpenAPI 3.1 document for a `KilnCMS.SchemaExport.json_schema/1` export.
  """
  @spec emit(map()) :: map()
  def emit(document) do
    defs = Map.get(document, "$defs", %{})
    kiln = Map.fetch!(document, "x-kiln")

    schemas =
      defs
      |> Map.new(fn {name, schema} -> {name, schema |> put_mappings(defs) |> rewrite_refs()} end)
      |> put_document(document, defs)

    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => Map.fetch!(document, "title"),
        "description" => Map.fetch!(document, "description"),
        "version" => kiln |> Map.fetch!("artifact_format_version") |> to_string()
      },
      "jsonSchemaDialect" => Map.fetch!(document, "$schema"),
      "components" => %{"schemas" => schemas},
      "x-kiln" => kiln
    }
  end

  # The root `oneOf` is what a fired artifact validates against; as a component
  # it is addressable the same way every other piece is.
  # Tagged by `type` like the block union is by `_type`, with the same explicit
  # mapping, so a generator builds a discriminated union over the documents too.
  defp put_document(schemas, %{"oneOf" => refs}, defs) do
    mapping = refs |> Enum.flat_map(&mapping_entry(&1, "type", defs)) |> Map.new()

    Map.put(schemas, "document", %{
      "title" => "Document",
      "description" => "Any document in a fired `:json` artifact, tagged by `type`.",
      "oneOf" => rewrite_refs(refs),
      "discriminator" => %{"propertyName" => "type", "mapping" => mapping}
    })
  end

  defp put_document(schemas, _document, _defs), do: schemas

  # Before the rewrite, so the members still resolve against `$defs`. A member
  # whose tag cannot be read (not a `$ref`, no `const`) is left out of the
  # mapping, where a generator falls back to its own rule for it alone.
  defp put_mappings(%{"discriminator" => %{"propertyName" => tag} = discriminator} = schema, defs)
       when not is_map_key(discriminator, "mapping") do
    mapping =
      schema
      |> Map.get("oneOf", [])
      |> Enum.flat_map(&mapping_entry(&1, tag, defs))
      |> Map.new()

    schema
    |> put_in(["discriminator", "mapping"], mapping)
    |> Map.new(fn {key, value} -> {key, put_mappings(value, defs)} end)
  end

  defp put_mappings(%{} = schema, defs),
    do: Map.new(schema, fn {key, value} -> {key, put_mappings(value, defs)} end)

  defp put_mappings(list, defs) when is_list(list), do: Enum.map(list, &put_mappings(&1, defs))
  defp put_mappings(other, _defs), do: other

  defp mapping_entry(%{"$ref" => @defs_prefix <> name}, tag, defs) do
    case get_in(defs, [name, "properties", tag, "const"]) do
      value when is_binary(value) -> [{value, @components_prefix <> name}]
      _ -> []
    end
  end

  defp mapping_entry(_member, _tag, _defs), do: []

  # Only `$ref` values: a description or an example that happens to contain
  # `#/$defs/` is text, not a reference.
  defp rewrite_refs(%{} = schema) do
    Map.new(schema, fn
      {"$ref", @defs_prefix <> name} -> {"$ref", @components_prefix <> name}
      {key, value} -> {key, rewrite_refs(value)}
    end)
  end

  defp rewrite_refs(list) when is_list(list), do: Enum.map(list, &rewrite_refs/1)
  defp rewrite_refs(other), do: other
end
