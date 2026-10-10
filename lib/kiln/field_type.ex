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
  a bespoke chooser) can attach a client hook to its input (below); one that
  needs a whole page of its own should ship an admin LiveView instead.

  ## Client hooks

  A type that wants behaviour in the browser (an address type-ahead, a map
  picker, a lookup against an external registry) declares `c:input_hook/1`.
  The editor then wraps the field's input(s) in

      <div id="cf-hook-<name>" phx-hook={hook}
           data-field="<name>" data-config={JSON of data}>

  so the hook sees every part of a composite field, not only one `<input>`.

  The hook itself is a **colocated hook** (`Phoenix.LiveView.ColocatedHook`)
  written in the type's own module. `projects/` compiles into the host
  application, so the hook is bundled into the editor's `app.js` at build time
  with the host's own hooks — no asset callback, no runtime-loaded script, and
  nothing for a `script-src 'self'` Content-Security-Policy to object to. A
  colocated hook is registered under its module's name
  (`Clinics.FieldTypes.Address.Autocomplete`), so a plugin's hooks cannot
  collide with the host's or another plugin's. `colocated_hook/2` spells that
  name; `mix kiln.plugins.doctor` checks it was actually bundled.

      defmodule Clinics.FieldTypes.Address do
        use Kiln.FieldType
        # `use`, not `import`: LiveView bundles colocated hooks only from
        # modules that `use Phoenix.Component`.
        use Phoenix.Component

        @impl Kiln.FieldType
        def input_hook(_definition),
          do: %{hook: Kiln.FieldType.colocated_hook(__MODULE__, "Autocomplete"), data: %{}}

        # Never rendered: compiling the template is what bundles the hook.
        @doc false
        def __hooks__(assigns) do
          ~H'''
          <script :type={Phoenix.LiveView.ColocatedHook} name=".Autocomplete">
            export default {
              mounted() {
                this.ref = 0
                this.handleEvent("kiln:field_reply", ({field, ref, reply, error}) => {
                  if (field !== this.el.dataset.field || ref !== this.ref) return
                  // render `reply` (or `error`) as suggestions …
                })
                // … and on (debounced) input:
                // this.pushEvent("kiln:field_event",
                //   {field: this.el.dataset.field, event: "suggest", params: {q}, ref: ++this.ref})
              }
            }
          </script>
          '''
        end
      end

  A hook works on **its own field's inputs only**. It writes values into them
  and dispatches an `input` event, so the editor form's ordinary change event
  carries them — the server stays the source of truth, and `cast/2` still
  validates whatever the hook filled in. Hooks are not handed the form's
  changeset or other fields' values.

  ## Server calls from a hook

  A hook that needs the server (to call an API whose key must not reach the
  browser) pushes `"kiln:field_event"` with `field`, `event`, `params` and a
  `ref` of its choosing. The editor checks that `field` names a custom field of
  the record being edited, then runs `c:handle_input_event/3` **in a task**,
  so a slow lookup never stalls the editor. The result comes back as a
  `"kiln:field_reply"` push event carrying the same `field` and `ref` plus
  either `reply` (from `{:ok, reply}`) or `error`. A newer event for the same
  field cancels an older one still in flight, so a type-ahead always shows the
  answer to the latest keystroke. Every hook on the page receives every reply;
  filter on `field` and `ref`.

  `data-config` is rendered into the page — never put a secret in
  `c:input_hook/1`'s `data`.

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
  One or two sentences shown under the type picker in the fields admin once an
  admin selects this type: what the field holds and what it is for ("A colour,
  picked from a swatch. For brand accents or a category's badge colour."). A
  plain string, like `c:label/0`. Defaults to `nil`, which shows nothing.
  """
  @callback description() :: String.t() | nil

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

  @doc ~S"""
  Extra `Kiln.Tokens` (#468) definitions this type can offer beyond the
  generic `[field:<name>]` substitution the slug/alias pattern engine
  (`KilnCMS.Slug.Pattern`) already gives every custom field for free — that
  generic path slugifies a scalar value and expands a map/list one empty,
  which is the honest answer for most types but not a **composite** one (a
  coordinate pair, a price-and-currency): those want to expose their own
  named parts (`[field:location.lat]`) or a custom string form instead of
  going blank.

  Defaults to `[]`. **Live since #804**: `KilnCMS.CMS.Slugs.type_token_definitions/1`
  collects these from the field definitions attached to a content type, and both
  the slug/alias derivation and the save-time pattern validation expand against
  them alongside the built-in vocabulary.

  Three rules, and the first two are traps rather than niceties:

    * **Scope the match to the field's own name, anchored.** `definition.name`
      is in scope, so `~r/\Afield:#{definition.name}\.lat\z/` rather than a
      bare `"field:lat"` or an unanchored `~r/field:lat/`. Nothing enforces
      this: `Kiln.Tokens.expand/3` takes the *first* matching definition, so a
      loose matcher on a type used by two fields of one content type
      deterministically resolves both to whichever field is collected first,
      with no error anywhere.
    * **Your name must contain a `.`, or the built-in swallows it.** The
      built-in `[field:<name>]` family matches `~r/\Afield:[a-z0-9_]+\z/` and
      is tried first, so a definition matching `"field:price_amount"` never
      runs — the generic path resolves it to the (absent) custom-field value
      and expands empty, and validation still answers `:ok`, so the operator
      sees no error. Dotted names like `field:price.amount` are outside the
      built-in's character class and reach you.
    * **Built-ins cannot be shadowed the other way either.** A type redefining
      `[title]` is ignored rather than surprising a pattern author.

  The field must exist before a pattern may name its token — until then nothing
  claims it and save-time validation truthfully rejects it as unknown.

  Building the list cannot fail a save: `KilnCMS.CMS.Slugs.type_token_definitions/1`
  rescues, and the type contributes nothing. **The `resolve` closures you return
  are also rescued per token** (`Kiln.Tokens.expand/3`), so one that raises on an
  unexpected context expands empty rather than taking down the write — but write
  them total anyway, since an expansion that silently vanishes becomes a slug
  that silently changes shape.
  """
  @callback tokens(definition :: struct()) :: [Kiln.Tokens.definition()]

  @doc """
  The JSON Schema for this type's **delivered** value (#430).

  `KilnCMS.SchemaExport` otherwise infers a shape from the editor widget —
  `c:input_parts/1` for a composite, `c:input_type/0` for a scalar. That
  inference is a guess about the *form*, and `c:cast/2` is free to disagree
  with it: `KilnCMS.CMS.FieldTypes.Recurrence` renders its exclusion dates as
  one text input but stores a **list**, and
  `KilnCMS.CMS.FieldTypes.Computed` renders a formula but stores whatever the
  expression evaluated to — a number, a boolean, a string.

  Implement this when `cast/2`'s return value is not what the widget suggests.
  Anything you return is used verbatim, so it should describe the JSON that
  reaches `custom_fields` on the fired artifact, `null` included.

  Optional: a type whose stored value matches its widget needs nothing here.
  """
  @callback json_schema(definition :: struct()) :: map()

  @typedoc "A client hook for the field's editor widget: see `c:input_hook/1`."
  @type input_hook :: %{required(:hook) => String.t(), optional(:data) => map()}

  @doc """
  The client hook to attach to this field's editor widget, or `nil` for none
  (see "Client hooks" above). `hook` is the hook's registered name — for a
  colocated hook, `colocated_hook/2`; `data` is JSON-encoded into the
  wrapper's `data-config` attribute, so it must be JSON-encodable and is
  **public**. Defaults to `nil`.

  A raise here is contained: the editor logs it and renders the field without
  its hook.
  """
  @callback input_hook(definition :: struct()) :: input_hook() | nil

  @doc """
  Answer a `"kiln:field_event"` pushed by this type's hook (see "Server calls
  from a hook" above). `event` and `params` are what the hook sent; `context`
  carries the field's `:definition`, the editing `:actor` and the `:org`.

  Runs in a task linked to the editor, never in the editor process itself.
  Return `{:ok, reply}` with a JSON-encodable reply, or `{:error, message}`;
  the hook receives one or the other. A raise or exit reaches the hook as a
  generic error and is logged. Bound your own I/O with a timeout: nothing else
  stops a hung request except the editor closing or a newer event for the
  same field.

  Treat `params` as untrusted input — any signed-in editor of the record can
  push any event.
  """
  @callback handle_input_event(event :: String.t(), params :: map(), context :: map()) ::
              {:ok, term()} | {:error, String.t()}

  @doc ~S"""
  The registered name of a colocated hook declared in `module` as
  `<script :type={ColocatedHook} name=".Name">` — the string
  `c:input_hook/1` returns as `hook`.

      iex> Kiln.FieldType.colocated_hook(Clinics.FieldTypes.Address, "Autocomplete")
      "Clinics.FieldTypes.Address.Autocomplete"
  """
  @spec colocated_hook(module(), String.t()) :: String.t()
  def colocated_hook(module, name) when is_atom(module) and is_binary(name),
    do: "#{inspect(module)}.#{String.trim_leading(name, ".")}"

  # `input_parts/1`, `tokens/1` and `description/0` were added after this
  # contract shipped.
  # `use Kiln.FieldType` defaults them, but a plugin that hand-rolls
  # `@behaviour Kiln.FieldType` is explicitly sanctioned (`mix
  # kiln.plugins.doctor` requires only `cast/2` and `name/0`), and such a
  # module would otherwise fail to compile under `--warnings-as-errors` on
  # upgrade. Optional here, defaulted there.
  # `json_schema/1` is deliberately *not* defaulted by `use Kiln.FieldType`:
  # `KilnCMS.SchemaExport` probes for it with `function_exported?` and falls
  # back to widget inference, so defining a default would mean every type
  # silently claiming to describe itself.
  # `input_hook/1` (#1918) is the same story: defaulted to `nil` by `use`.
  # `handle_input_event/3` is not defaulted — the editor probes for it, and a
  # type without one answers its hook's events with an error.
  @optional_callbacks input_parts: 1,
                      tokens: 1,
                      json_schema: 1,
                      description: 0,
                      input_hook: 1,
                      handle_input_event: 3

  @doc ~S"""
  `Float.parse/1`, made total — the numeric parse a custom field type's
  `c:cast/2` should reach for instead of the standard-library call.

  Same contract as `Float.parse/1`: `{float, remainder}` on success, `:error`
  otherwise.

      iex> Kiln.FieldType.parse_float("1.5")
      {1.5, ""}

      iex> Kiln.FieldType.parse_float("2.5kg")
      {2.5, "kg"}

      iex> Kiln.FieldType.parse_float("not a number")
      :error

  `Float.parse/1` itself is **not** total, and *how* it fails is toolchain-
  dependent: on a literal that overflows a double it returns the bare atom
  `:error` on Elixir 1.20 but **raises** `ArgumentError` out of
  `:erlang.list_to_float/1` on 1.19 (the version `.tool-versions` pins and CI
  runs). A `cast/2` runs on every content write, including public ones, so
  there the difference is a validation message on one toolchain and a 500 on
  the other. Both failures are normalized to `:error` here.

      Kiln.FieldType.parse_float(String.duplicate("9", 400) <> ".0")
      #=> :error

  `KilnCMS.CMS.FieldTypes.Geolocation` and the example overlay's money type
  (`projects/example/field_types/money.ex`) both parse their parts through
  this.
  """
  @spec parse_float(String.t()) :: {float(), binary()} | :error
  def parse_float(text) when is_binary(text) do
    Float.parse(text)
  rescue
    ArgumentError -> :error
  end

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
      def description, do: nil

      @impl Kiln.FieldType
      def input_type, do: "text"

      @impl Kiln.FieldType
      def input_attrs(_definition), do: %{}

      @impl Kiln.FieldType
      def input_parts(_definition), do: []

      @impl Kiln.FieldType
      def tokens(_definition), do: []

      @impl Kiln.FieldType
      def input_hook(_definition), do: nil

      defoverridable name: 0,
                     label: 0,
                     description: 0,
                     input_type: 0,
                     input_attrs: 1,
                     input_parts: 1,
                     tokens: 1,
                     input_hook: 1
    end
  end
end
