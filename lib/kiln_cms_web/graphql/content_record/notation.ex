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
      type name, e.g. `post` or a dynamic type's name). `inverse` names a
      reverse field instead, by the `inverse_name` a reference field gives
      its other side (e.g. `used_in_recipes`): it stands for that field and
      source type together, so it is not combined with `field` or
      `sourceType`. Only sources the reader may read are listed. `limit`
      defaults to, and is capped at, 100.
      """
      field :referenced_by, non_null(list_of(non_null(:content_referrer))) do
        arg :field, :string
        arg :source_type, :string
        arg :inverse, :string
        arg :limit, :integer
        arg :offset, :integer
        complexity &KilnCMSWeb.GraphqlLimits.list_complexity/3
        resolve &KilnCMSWeb.Graphql.References.referenced_by/3
      end
    end
  end

  @doc """
  The typed readers of admin-defined custom fields (#2290), shared by the
  interface and every object that implements it.

  The schema is compiled and the same for every site, so these take the field's
  `name` and type the *accessor*: `customFloat(name: "price")` is a `Float` or
  `null`, whatever the site names its fields. A name that is unknown, deleted,
  renamed, of another kind, or private to the reader is `null` (never an
  error), because a client cannot know the site's current definitions.
  `fields(names:)` lists the named fields as `CustomFieldValue`s, up to 50.

  `KilnCMSWeb.Graphql.CustomFields` resolves them, one definitions read per
  type per document.
  """
  defmacro custom_field_accessors do
    quote do
      @desc "The `string`, `text`, `url`, `select` or `user` custom field `name`, or null."
      field :custom_string, :string do
        arg :name, non_null(:string)
        resolve &KilnCMSWeb.Graphql.CustomFields.custom_string/3
      end

      @desc "The `integer` custom field `name`, or null."
      field :custom_int, :integer do
        arg :name, non_null(:string)
        resolve &KilnCMSWeb.Graphql.CustomFields.custom_int/3
      end

      @desc "The `float` custom field `name`, or null."
      field :custom_float, :float do
        arg :name, non_null(:string)
        resolve &KilnCMSWeb.Graphql.CustomFields.custom_float/3
      end

      @desc "The `boolean` custom field `name`, or null."
      field :custom_boolean, :boolean do
        arg :name, non_null(:string)
        resolve &KilnCMSWeb.Graphql.CustomFields.custom_boolean/3
      end

      @desc "The `date` custom field `name`, or null."
      field :custom_date, :date do
        arg :name, non_null(:string)
        resolve &KilnCMSWeb.Graphql.CustomFields.custom_date/3
      end

      @desc "The `datetime` custom field `name`, or null."
      field :custom_date_time, :datetime do
        arg :name, non_null(:string)
        resolve &KilnCMSWeb.Graphql.CustomFields.custom_date_time/3
      end

      @desc """
      The custom fields `names` (at most 50), each as a `CustomFieldValue`
      narrowed with `... on FloatValue { value }`. A name that is unknown,
      empty, private to the reader or of no value is left out. Priced at one
      plus the child's price per name.
      """
      field :fields, non_null(list_of(non_null(:custom_field_value))) do
        arg :names, non_null(list_of(non_null(:string)))
        complexity &KilnCMSWeb.GraphqlLimits.custom_fields_complexity/3
        resolve &KilnCMSWeb.Graphql.CustomFields.fields/3
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
          KilnCMSWeb.Graphql.ContentRecord.Notation.custom_field_accessors()
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
