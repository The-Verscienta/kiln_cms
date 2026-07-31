defmodule Kiln.FieldType do
  @moduledoc """
  The contract for a **plugin-contributed custom field type** (decision D18 —
  the custom-field-type registry).

  Core field types (`:string`, `:integer`, `:media`, …) are built into
  `KilnCMS.CMS.FieldDefinition` and `KilnCMS.CMS.Changes.ApplyCustomFields`. A
  plugin adds its own — a star rating, a color, a coordinate pair — by
  declaring a module:

      defmodule Ratings.FieldTypes.StarRating do
        use Kiln.FieldType

        @impl Kiln.FieldType
        def cast(value, _definition) do
          case Integer.parse(to_string(value)) do
            {n, ""} when n in 1..5 -> {:ok, n}
            _ -> {:error, "must be a whole number from 1 to 5"}
          end
        end

        @impl Kiln.FieldType
        def input_type, do: "number"

        @impl Kiln.FieldType
        def input_attrs(_definition), do: %{min: 1, max: 5}
      end

  and listing it from its plugin entry module:

      @impl Kiln.Plugin
      def field_types, do: [Ratings.FieldTypes.StarRating]

  Admins then pick the type in the fields admin (`/editor/fields`) like any
  core type. `cast/2` runs on every content write — the returned value must be
  **JSON-native** (string / number / boolean / map / list of those), because
  it's stored in the `custom_fields` jsonb column and served on delivery
  as-is. The content editor renders the field as
  `<input type={input_type()} {input_attrs(definition)}>`, so standard HTML
  input kinds (number, color, range, …) come free.

  ## Composite values

  A type whose value is a **map of parts** (a coordinate pair, a price and a
  currency) declares those parts with `c:input_parts/1`. The editor then
  renders one labelled input per part, named into the field's own map
  (`…[custom_fields][<field>][<part>]`), and `cast/2` receives that map —
  string-keyed, values as submitted. `KilnCMS.CMS.FieldTypes.Geolocation` is
  the worked example. A type needing more than a grid of inputs (a map picker,
  a bespoke chooser) should ship an admin LiveView instead.

  ## Built-in types

  `:geolocation` and `:computed` ship in-tree and are implemented against this
  very contract rather than special-cased in the host — they're the reference
  implementations, and they register through
  `KilnCMS.CMS.FieldTypes.builtin/0` exactly as a plugin's do through
  `c:Kiln.Plugin.field_types/0`. Their names are reserved: a plugin may not
  reuse them (`mix kiln.plugins.doctor`).
  """

  @doc """
  The type's machine name — the `field_type` value stored on
  `FieldDefinition` rows. Must not collide with a core type or another
  plugin's (checked by `mix kiln.plugins.doctor`). Defaults to the module's
  last segment, underscored (`My.FieldTypes.StarRating` → `:star_rating`).
  """
  @callback name() :: atom()

  @doc "Human label shown in the fields admin. Defaults to the humanized name."
  @callback label() :: String.t()

  @doc """
  Coerce + validate one submitted value against a definition. Called with the
  raw form/API value (never blank — blank handling, `required`, and `default`
  are the host's job). Return a JSON-native value or a human message.
  """
  @callback cast(value :: term(), definition :: struct()) ::
              {:ok, term()} | {:error, String.t()}

  @doc ~S(The HTML `type` for the editor's `<input>`. Defaults to `"text"`.)
  @callback input_type() :: String.t()

  @doc """
  Extra HTML attributes for the editor's `<input>` (e.g. `%{min: 1, max: 5}`),
  per definition. Defaults to none.
  """
  @callback input_attrs(definition :: struct()) :: %{optional(atom()) => term()}

  @typedoc """
  One part of a composite field's editor widget: the key it occupies inside the
  field's value map, its label, its HTML input `type`, and any extra input
  attributes.
  """
  @type input_part :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          optional(:type) => String.t(),
          # Whether this part carries the definition's `required` flag. Defaults
          # to true; set false for a part that stays optional even when the
          # field as a whole is required (a geolocation's place name or zoom).
          optional(:required?) => boolean(),
          optional(:attrs) => %{optional(atom()) => term()}
        }

  @doc """
  The parts of a **composite** value, rendered as one labelled input each and
  submitted as a map under the field's own key. Defaults to `[]` — a single
  `<input>` of `c:input_type/0`.
  """
  @callback input_parts(definition :: struct()) :: [input_part()]

  # `input_parts/1` was added after this contract shipped. `use Kiln.FieldType`
  # defaults it, but a plugin that hand-rolls `@behaviour Kiln.FieldType` is
  # explicitly sanctioned (`mix kiln.plugins.doctor` requires only `cast/2` and
  # `name/0`), and such a module would otherwise fail to compile under
  # `--warnings-as-errors` on upgrade. Optional here, defaulted there.
  @optional_callbacks input_parts: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.FieldType

      @impl Kiln.FieldType
      # `My.FieldTypes.StarRating` → :star_rating. `String.to_atom` is safe
      # here: it runs on the module's own name (compile-time code, D4 — no
      # user input), never per-request.
      # sobelow_skip ["DOS.StringToAtom"]
      def name do
        __MODULE__
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
        |> String.to_atom()
      end

      @impl Kiln.FieldType
      def label do
        name() |> to_string() |> String.replace("_", " ") |> String.capitalize()
      end

      @impl Kiln.FieldType
      def input_type, do: "text"

      @impl Kiln.FieldType
      def input_attrs(_definition), do: %{}

      @impl Kiln.FieldType
      def input_parts(_definition), do: []

      defoverridable name: 0, label: 0, input_type: 0, input_attrs: 1, input_parts: 1
    end
  end
end
