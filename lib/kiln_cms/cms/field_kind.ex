defmodule KilnCMS.CMS.FieldKind do
  @moduledoc """
  The **GraphQL kind** of a custom field (#2290): which typed accessor serves
  it and which `CustomFieldValue` member wraps it.

  The GraphQL schema is compiled and org-independent, while
  `KilnCMS.CMS.FieldDefinition` rows change at runtime. This module is the
  bridge: given a definition it says how the value is typed, so the schema never
  has to know a field's name.

  | kind         | field types                                                  |
  | ------------ | ------------------------------------------------------------ |
  | `:string`    | `:string`, `:text`, `:url`, `:select`, `:user`, `:email`,    |
  |              | `:telephone`, `:color`, `:slug`, `:time`                     |
  | `:int`       | `:integer`                                                   |
  | `:float`     | `:float`                                                     |
  | `:boolean`   | `:boolean`                                                   |
  | `:date`      | `:date`                                                      |
  | `:datetime`  | `:datetime`                                                  |
  | `:group`     | `:group` (sub-fields come from `group_of_id` definitions)    |
  | `:reference` | `:reference`                                                 |
  | `:media`     | `:media`                                                     |
  | `:geolocation` | `:geolocation` (`lat`, `lng`, `label`, `zoom`)             |
  | `:list`      | any definition with `multiple: true`                         |
  | `:json`      | anything else: `:json`, `:range`, `:key_value`, `:link`, `:computed`, `:datetime_range`, `:recurrence`, |
  |              | and a plugin type that does not implement `c:Kiln.FieldType.graphql_kind/1` |

  Core types are mapped here directly. A `Kiln.FieldType` module (built-in or
  plugin) answers through the optional `c:Kiln.FieldType.graphql_kind/1`,
  probed with `function_exported?/3`; no answer, or an answer outside
  `t:scalar_kind/0`, is `:json` (a plugin cannot name a composite kind). A type that does not fit one scalar therefore
  needs no code to be served safely.

  `names/0` of `KilnCMS.CMS.FieldTypes` is covered exhaustively by this
  module's test, so registering a type that `kind_for/1` cannot place fails CI.
  """

  alias KilnCMS.CMS.FieldTypes

  @typedoc "Kinds a single (non-`multiple`) value can have."
  @type item_kind ::
          :string
          | :int
          | :float
          | :boolean
          | :date
          | :datetime
          | :group
          | :reference
          | :media
          | :geolocation
          | :json

  @typedoc "A kind as served: an `t:item_kind/0`, or `:list` for a `multiple` field."
  @type t :: item_kind() | :list

  @typedoc "What a `Kiln.FieldType` may answer from `graphql_kind/1`."
  @type scalar_kind :: :string | :int | :float | :boolean | :date | :datetime | :json

  @scalar_kinds [:string, :int, :float, :boolean, :date, :datetime, :json]

  @core %{
    string: :string,
    text: :string,
    url: :string,
    select: :string,
    # Stored as the user's id (always private, `KilnCMS.CMS.PrivateFields`).
    user: :string,
    integer: :int,
    float: :float,
    boolean: :boolean,
    date: :date,
    datetime: :datetime,
    media: :media,
    # A fixed shape (`lat`/`lng` and optional `label`/`zoom`), so it is typed
    # here rather than through the plugin callback, which names scalars only.
    geolocation: :geolocation,
    reference: :reference,
    group: :group
  }

  @doc """
  The kind a definition's value is served as.

  `definition` is a `KilnCMS.CMS.FieldDefinition` or any map with a
  `:field_type` atom and, optionally, `:multiple`. A `multiple` definition is
  `:list` whatever its item type; use `item_kind_for/1` for what the items are.
  """
  @spec kind_for(%{required(:field_type) => atom(), optional(any()) => any()}) :: t()
  def kind_for(%{multiple: true}), do: :list
  def kind_for(definition), do: item_kind_for(definition)

  @doc """
  The kind of one value of the field, ignoring `multiple`: the element kind of
  a `:list`, and the same as `kind_for/1` otherwise.
  """
  @spec item_kind_for(%{required(:field_type) => atom(), optional(any()) => any()}) ::
          item_kind()
  def item_kind_for(%{field_type: type} = definition) when is_atom(type) do
    case @core do
      %{^type => kind} -> kind
      _ -> kind_from_module(FieldTypes.get(type), definition)
    end
  end

  # Public for the test: the registry only resolves registered modules, and
  # the callback probe must be provable for ones that are not.
  @doc false
  @spec kind_from_module(module() | nil, map()) :: item_kind()
  def kind_from_module(nil, _definition), do: :json

  def kind_from_module(module, definition) do
    if Code.ensure_loaded?(module) and function_exported?(module, :graphql_kind, 1) do
      case module.graphql_kind(definition) do
        kind when kind in @scalar_kinds -> kind
        _ -> :json
      end
    else
      :json
    end
  end
end
