defmodule KilnCMS.CMS.FieldTypes do
  @moduledoc """
  The custom-field **type registry**: the core value types, the built-in
  `Kiln.FieldType` implementations, and every plugin-contributed one
  (decision D18).

  Three buckets, in increasing distance from the host:

    * **core** (`:string`, `:date`, `:media`, …) — coerced by
      `Changes.ApplyCustomFields` itself;
    * **built-in** (`:geolocation` #428, `:computed` #429) — in-tree modules
      written against `Kiln.FieldType`, dispatched through exactly the same
      seam a plugin's type is. They ship in core but are not *special-cased*
      in core, which is the point: they double as the reference
      implementations of the contract;
    * **plugin** — contributed via `c:Kiln.Plugin.field_types/0`.

  Like the block union, plugin types are resolved at **compile time** from
  `config :kiln_cms, :plugins` — `mix kiln.plugins.doctor` (in precommit)
  fails loudly on name collisions or contract violations, so drift between
  the baked registry and the config can't ship.

  Consumers:

    * `KilnCMS.CMS.FieldDefinition` validates `field_type` against `names/0`;
    * `Changes.ApplyCustomFields` dispatches unknown-to-core types to the
      plugin module's `cast/2` on every content write;
    * the content editor renders plugin types via `input_type/0` +
      `input_attrs/1`; the fields admin labels them via `label/0`.
  """

  defmodule Capability do
    @moduledoc false

    # The list capability (#2680) of one `Kiln.FieldType` module, as the
    # registry below bakes it and `mix kiln.plugins.doctor` checks it. Plugin
    # code: a raise answers "not list-capable".

    @doc false
    @spec list_capable?(module()) :: boolean()
    def list_capable?(module), do: answers_true?(module, :multiple?) and scalar?(module)

    @doc false
    @spec unique_items?(module()) :: boolean()
    def unique_items?(module), do: answers_true?(module, :unique_items?)

    @doc false
    # The definition the composite probe hands `input_parts/1`: a list field
    # of the type, with the editor input given (or none).
    @spec probe(module(), String.t() | nil) :: map()
    def probe(module, widget \\ nil),
      do: %{
        name: "probe",
        label: "Probe",
        field_type: module.name(),
        widget: widget,
        multiple: true
      }

    defp answers_true?(module, callback) do
      Code.ensure_loaded?(module) and function_exported?(module, callback, 0) and
        apply(module, callback, []) == true
    rescue
      _exception -> false
    end

    defp scalar?(module) do
      not function_exported?(module, :input_parts, 1) or module.input_parts(probe(module)) == []
    rescue
      _exception -> false
    end
  end

  # The built-in value types, coerced by `Changes.ApplyCustomFields` itself.
  # Kept JSON-native so values round-trip cleanly through the `custom_fields`
  # jsonb column (dates as ISO-8601 strings; `:media`/`:reference` as small
  # write-time snapshot maps; `:group` as an object, or a list of them, keyed
  # by its sub-fields). `:group` is core rather than a `Kiln.FieldType`
  # because coercing it recurses into `ApplyCustomFields` per sub-field,
  # which only the host can do.
  @core [
    :string,
    :text,
    :integer,
    :float,
    :boolean,
    :date,
    :datetime,
    :url,
    :select,
    :media,
    :reference,
    :group,
    # Mixed typed items (#2282): a list of items, each of one of the field's
    # item types (`FieldDefinition.flex_of_id` rows). Core for `:group`'s
    # reason — coercing it recurses into `ApplyCustomFields` per item type.
    :flexible,
    # A console account of the site (#2044): stored as the user's id, and
    # always private (`KilnCMS.CMS.PrivateFields`).
    :user
  ]

  # The in-tree `Kiln.FieldType` implementations. Listed here rather than
  # discovered, so the registry stays a literal (same stance as `@core`).
  @builtin_modules [
    KilnCMS.CMS.FieldTypes.Geolocation,
    KilnCMS.CMS.FieldTypes.Computed,
    # Event support (#480). Neither is an "event type" on its own — a dynamic
    # content type carrying a `datetime_range` *is* the event, which is what
    # keeps Event a thing an operator composes rather than one Kiln hardcodes.
    KilnCMS.CMS.FieldTypes.DatetimeRange,
    KilnCMS.CMS.FieldTypes.Recurrence,
    # Scalar formats (#2278): a string (or JSON structure) the type validates
    # and normalises, so an editor cannot save a malformed address or colour.
    KilnCMS.CMS.FieldTypes.Email,
    KilnCMS.CMS.FieldTypes.Telephone,
    KilnCMS.CMS.FieldTypes.Color,
    KilnCMS.CMS.FieldTypes.Slug,
    KilnCMS.CMS.FieldTypes.TimeField,
    KilnCMS.CMS.FieldTypes.Json,
    # Composite values (#2278), all stored as JSON and served as generic JSON.
    KilnCMS.CMS.FieldTypes.Range,
    KilnCMS.CMS.FieldTypes.KeyValue,
    KilnCMS.CMS.FieldTypes.Link,
    # A structured postal address (#2279): one object, validated and normalized.
    KilnCMS.CMS.FieldTypes.Address
  ]

  # name → module, baked at compile time (plugins are compile-time code, D4).
  @builtin Map.new(@builtin_modules, &{&1.name(), &1})
  @plugin Map.new(Kiln.Plugins.field_types(), &{&1.name(), &1})

  # The `Kiln.FieldType` modules that may hold a list (#2680), in registry
  # order (built-in, then plugin): each exports `multiple?/0` answering exactly
  # `true`, and is a scalar — its `input_parts/1` is `[]` (a composite value
  # is a repeating `:group`'s job). Read once here, at compile time, so the
  # guards built on `KilnCMS.CMS.ScalarLists.types/0` see plugin types too. A
  # module whose answer raises is not list-capable; `mix kiln.plugins.doctor`
  # reports it.
  @list_modules Enum.filter(
                  @builtin_modules ++ Kiln.Plugins.field_types(),
                  &__MODULE__.Capability.list_capable?/1
                )

  @list_capable Enum.map(@list_modules, & &1.name())
  @unique_items for module <- @list_modules,
                    __MODULE__.Capability.unique_items?(module),
                    do: module.name()

  @doc "The core field types (coerced by `ApplyCustomFields` itself)."
  @spec core() :: [atom()]
  def core, do: @core

  @doc "The in-tree `Kiln.FieldType` modules."
  @spec builtin() :: [module()]
  def builtin, do: @builtin_modules

  @doc """
  Names a plugin may not claim: the core types plus the built-in ones. Used by
  `mix kiln.plugins.doctor` to reject collisions.
  """
  @spec reserved() :: [atom()]
  def reserved, do: @core ++ Map.keys(@builtin)

  @doc "Every registered field type: core, then built-in, then plugin types."
  @spec names() :: [atom()]
  def names, do: reserved() ++ Map.keys(@plugin)

  @doc """
  The `Kiln.FieldType` names that may hold a list (#2680): a built-in or
  plugin type whose `c:Kiln.FieldType.multiple?/0` answers `true` and whose
  value is a scalar (`c:Kiln.FieldType.input_parts/1` is `[]`). Built-in
  first, then plugin, each in registry order. Decided at compile time.
  """
  @spec list_capable() :: [atom()]
  def list_capable, do: @list_capable

  @doc """
  Whether a list of the `Kiln.FieldType` named `name` drops repeated items:
  it is list-capable (`list_capable/0`) and its
  `c:Kiln.FieldType.unique_items?/0` answers `true`. Decided at compile time.
  """
  @spec unique_items?(atom()) :: boolean()
  def unique_items?(name), do: name in @unique_items

  @doc """
  The `Kiln.FieldType` module registered under `name`, or nil. Core types have
  no module (they're coerced by the host), so they resolve to nil.
  """
  @spec get(atom()) :: module() | nil
  # `apply/3` (deliberate, hence the credo disable) keeps the plugin lookup
  # opaque to the type checker: in a build with no plugin field types `@plugin`
  # is a literal empty map, and every consumer's plugin branch would otherwise
  # be flagged unreachable — true for that build, wrong for the feature.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  def get(name), do: Map.get(@builtin, name) || apply(Map, :get, [@plugin, name])
end
