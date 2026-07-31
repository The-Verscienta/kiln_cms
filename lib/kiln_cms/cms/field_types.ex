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

  # The built-in value types, coerced by `Changes.ApplyCustomFields` itself.
  # Kept JSON-native so values round-trip cleanly through the `custom_fields`
  # jsonb column (dates as ISO-8601 strings; `:media`/`:reference` as small
  # write-time snapshot maps).
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
    :reference
  ]

  # The in-tree `Kiln.FieldType` implementations. Listed here rather than
  # discovered, so the registry stays a literal (same stance as `@core`).
  @builtin_modules [
    KilnCMS.CMS.FieldTypes.Geolocation,
    KilnCMS.CMS.FieldTypes.Computed
  ]

  # name → module, baked at compile time (plugins are compile-time code, D4).
  @builtin Map.new(@builtin_modules, &{&1.name(), &1})
  @plugin Map.new(Kiln.Plugins.field_types(), &{&1.name(), &1})

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
