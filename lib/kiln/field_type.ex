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
  input kinds (number, color, range, …) come free; a field type needing a
  bespoke widget should ship an admin LiveView instead.
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

      defoverridable name: 0, label: 0, input_type: 0, input_attrs: 1
    end
  end
end
