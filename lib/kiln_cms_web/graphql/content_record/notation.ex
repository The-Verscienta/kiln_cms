defmodule KilnCMSWeb.Graphql.ContentRecord.Notation do
  @moduledoc """
  Schema macros for `KilnCMSWeb.Graphql.ContentRecord`.

  `implement_content_record/1` runs in the GraphQL schema module and emits
  one `extend object` per content type on the GraphQL surface, adding the
  `ContentRecord` interface and its `references` / `referencedBy` fields to
  the object AshGraphql generated. AshGraphql adds its objects in a phase that
  runs before Absinthe applies type extensions, so the extension finds them.

  The types are read from the schema's `:content_domains` when the schema
  compiles, so a project overlay's types (`config/project.exs`) implement the
  interface with no core edit, the same way they reach the rest of the schema.
  """

  @doc """
  The `references` and `referencedBy` fields, shared by the interface and
  every object that implements it (Absinthe requires the same arguments on
  both).

  Both are priced like any other to-many relationship
  (`KilnCMSWeb.GraphqlLimits.list_complexity/3`): `limit` rows, or 5 without
  one.
  """
  defmacro reference_fields do
    quote do
      @desc """
      The records this one links to through the `:reference` custom field
      `field`, in the field's order. Only targets the reader may read are
      listed, so a draft target is invisible to an anonymous reader.
      `limit` defaults to, and is capped at, 100.
      """
      field :references, non_null(list_of(non_null(:content_reference))) do
        arg :field, non_null(:string)
        arg :limit, :integer
        arg :offset, :integer
        complexity &KilnCMSWeb.GraphqlLimits.list_complexity/3
        resolve &KilnCMSWeb.Graphql.References.references/3
      end

      @desc """
      The records that link to this one through a `:reference` custom field,
      optionally only through `field` and only from `sourceType` (a content
      type name, e.g. `post` or a dynamic type's name). Only sources the
      reader may read are listed. `limit` defaults to, and is capped at, 100.
      """
      field :referenced_by, non_null(list_of(non_null(:content_referrer))) do
        arg :field, :string
        arg :source_type, :string
        arg :limit, :integer
        arg :offset, :integer
        complexity &KilnCMSWeb.GraphqlLimits.list_complexity/3
        resolve &KilnCMSWeb.Graphql.References.referenced_by/3
      end
    end
  end

  @doc """
  One `extend object` per content type in `domains` (the schema's
  `:content_domains`, the list it hands AshGraphql). See the moduledoc.
  """
  defmacro implement_content_record(domains) do
    {domains, _binding} = Code.eval_quoted(domains, [], __CALLER__)

    domains
    |> content_object_types()
    |> Enum.map(fn type ->
      quote do
        extend object(unquote(type)) do
          interface :content_record
          KilnCMSWeb.Graphql.ContentRecord.Notation.reference_fields()
        end
      end
    end)
  end

  @doc """
  The GraphQL object identifiers of every content resource in `domains`: each
  compiled type and the shared `Entry` tier.
  """
  @spec content_object_types([module()]) :: [atom()]
  def content_object_types(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&content_resource?/1)
    |> Enum.map(&AshGraphql.Resource.Info.type/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc false
  # Whether `resource` is a content resource: a compiled type or the `Entry`
  # tier. Shared with `KilnCMSWeb.Graphql.ReferenceWrites.Notation`.
  @spec content_resource?(module()) :: boolean()
  def content_resource?(resource) do
    Code.ensure_compiled!(resource)

    function_exported?(resource, :__kiln_content_type__, 0) or
      function_exported?(resource, :__kiln_dynamic_entry__, 0)
  end
end
