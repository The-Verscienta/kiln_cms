defmodule KilnCMS.CMS.FieldTypes do
  @moduledoc """
  The custom-field **type registry**: the core value types plus every
  plugin-contributed `Kiln.FieldType` (decision D18).

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

  # name → module, baked at compile time (plugins are compile-time code, D4).
  @plugin Map.new(Kiln.Plugins.field_types(), &{&1.name(), &1})

  @doc "The built-in field types (coerced by `ApplyCustomFields` itself)."
  @spec core() :: [atom()]
  def core, do: @core

  @doc "Every registered field type: core first, then plugin types."
  @spec names() :: [atom()]
  def names, do: @core ++ Map.keys(@plugin)

  @doc "The `Kiln.FieldType` module registered under `name`, or nil (core types included)."
  @spec get(atom()) :: module() | nil
  # `apply/3` (deliberate, hence the credo disable) keeps the lookup opaque
  # to the type checker: in a build with no plugin field types `@plugin` is a
  # literal empty map, and every consumer's plugin branch would otherwise be
  # flagged unreachable — true for that build, wrong for the feature.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  def get(name), do: apply(Map, :get, [@plugin, name])
end
