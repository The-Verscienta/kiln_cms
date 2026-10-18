defmodule KilnCMS.CMS.Computed do
  @moduledoc """
  The expression language behind **computed custom fields** (#429): a value
  derived from the rest of the document rather than typed by an editor —
  reading time, word count, a normalized slug, a price total.

  Custom fields are *data* (decision D4 keeps types compile-time but fields
  admin-defined), so a computed field can't carry an Elixir function: it would
  have to be stored and evaluated at runtime, and KilnCMS never evaluates
  stored code. Instead a definition carries a small **template string**, which
  is parsed into an AST and interpreted here. There is no `eval`, no atom
  creation, and no way to reach anything but the document's own values.

  The template is parsed at *definition* time only to validate it
  (`Validations.ComputeExpression`); the AST is not persisted, so each
  evaluation re-parses. That is deliberate for now — the formula is bounded to
  2,000 characters and parsing is linear — but it does mean a re-fire sweep
  re-parses once per record per field. Cache the compiled form here if that
  ever shows up in a profile.

  ## Syntax

      {{ reading_time(body) }} min read
      {{ word_count(body) }}
      {{ slugify(title) }}
      {{ sum(price, shipping) }}
      {{ title }} — {{ field.author }}

  A template whose whole (trimmed) text is a single `{{ … }}` yields that
  expression's **native** value — a number stays a number. Anything else is
  string interpolation, and every segment is stringified and joined.

  ## References

  Bare identifiers resolve against the document's own scalars first —
  `title`, `slug`, `locale`, `excerpt`, `seo_title`, `seo_description`,
  `seo_keywords`, and `body` (the block tree's plain text) — then against the
  record's other custom fields by name. `field.<name>` skips the document
  scalars and always means the custom field, which is how you reference a
  custom field that happens to share a reserved name.

  A reference that resolves to nothing is **blank**, not an error: field
  definitions are added and removed independently of the formulas that mention
  them, so an unknown name must not break saving a document. Function names and
  arities *are* checked, at parse time, so a typo in `slugfy(title)` is caught
  when the field is defined rather than silently blanking every record.

  ## Computed fields feeding each other

  A formula may reference another **computed** field, and sees the value that
  field derives on this same write: `{{ product(subtotal, 1.2) }}` over a
  computed `subtotal`. `derive/3` evaluates a type's computed fields in
  dependency order (`order/1`, by the names `references/1` finds in each
  formula), so each one sees the values of the fields it reads. Every
  evaluation site — the write, the computed-only refresh, the fire, the slug
  pattern's `[field:…]` token — goes through `derive/3`, so the four can't
  order them differently.

  A cycle (`a` reads `b`, `b` reads `a`, or `a` reads itself) has no value, so
  `cycle/1` finds one and `Validations.ComputeExpression` refuses the
  definition that would close it. Should one exist anyway (a row written
  before the check, a race between two admins), `order/1` puts the fields on
  it last, in their given order, and each sees nothing for a field not yet
  evaluated — deterministic, so the stored and fired values still agree.

  ## Functions

  | Function | Result |
  | --- | --- |
  | `word_count(text)` | words in `text` |
  | `reading_time(text)` / `reading_time(text, wpm)` | whole minutes, `wpm` defaults to `config :kiln_cms, :reading_time_wpm` (230) |
  | `char_count(text)` | graphemes in `text` |
  | `slugify(text)` | URL-safe slug |
  | `upcase/downcase/capitalize/trim(text)` | the transformed string |
  | `truncate(text, n)` | `text` cut to `n` characters, ellipsized |
  | `concat(a, b, …)` | the arguments stringified and joined |
  | `join(sep, a, b, …)` | the non-blank arguments joined by `sep` |
  | `sum/min/max(a, b, …)` | over the numeric arguments (non-numbers ignored) |
  | `product(a, b, …)` | the arguments multiplied — `nil` unless every one is numeric |
  | `subtract(a, b)` / `divide(a, b)` | `nil` if either side isn't numeric (or on divide by zero) |
  | `round(n)` / `round(n, precision)` | `n` rounded |
  | `replace(text, find, replacement)` | every `find` in `text` replaced |
  | `if(condition, then)` / `if(condition, then, otherwise)` | `then` when `condition` holds, else `otherwise` (or blank) |
  | `equals/greater_than/less_than(a, b)` | a boolean; numbers compare as numbers, text ignoring case |
  | `contains(text, part)` | whether `part` occurs in `text`, ignoring case |
  | `is_empty(value)` / `not(condition)` | a boolean |
  | `and/or(a, b, …)` | a boolean over the arguments' truthiness |
  | `default(a, b)` | `a` unless blank, else `b` |
  | `days_between(start, end)` | whole days from `start` to `end` (ISO dates or datetimes) |
  | `year(date)` | the date's year |
  | `format_date(date, pattern)` | the date through `Calendar.strftime/2` |

  A condition holds unless it is blank, `false`, `0`, the text `"false"`, or an
  empty list or map, so an unticked boolean field and an empty one both read as
  "no". A list or map value (a gallery, a reference) is empty only when it
  holds nothing.

  An interpolated template whose expressions **all** come out blank is blank
  itself: `{{ size }} EU` on a record without a size has no value, rather than
  the value "EU".

  There is deliberately no `today()`: a formula is evaluated on write *and*
  re-evaluated on fire, and a clock would make the stored value and the fired
  one disagree on any day but the one the record was saved.

  Evaluation is **total**: every function returns a value or `nil`, and
  `evaluate/2` never raises — a computed field can't make a document
  unsaveable.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  require Logger

  alias KilnCMS.Slug

  @typedoc """
  A parsed template: literal text and expression segments, in order. Public
  rather than opaque because `KilnCMS.CMS.Computed.Recipes` recognizes a
  recipe by the shape of its parse.
  """
  @type template :: [{:text, String.t()} | {:expr, ast()}]

  @typedoc "One parsed expression: a literal, a reference, or a call."
  @type ast ::
          {:lit, String.t() | number()} | {:ref, String.t()} | {:call, String.t(), [ast()]}

  # Allowed function names → allowed arities (`:variadic` for any count ≥ 1).
  # The allowlist *is* the sandbox: a name that isn't here fails to parse.
  # `catalog/0` carries the wording the formula builder shows for each one.
  @functions %{
    "word_count" => [1],
    "char_count" => [1],
    "reading_time" => [1, 2],
    "slugify" => [1],
    "upcase" => [1],
    "downcase" => [1],
    "capitalize" => [1],
    "trim" => [1],
    "truncate" => [2],
    "replace" => [3],
    "concat" => :variadic,
    "join" => :variadic,
    "sum" => :variadic,
    "subtract" => [2],
    "product" => :variadic,
    "divide" => [2],
    "round" => [1, 2],
    "min" => :variadic,
    "max" => :variadic,
    "if" => [2, 3],
    "equals" => [2],
    "greater_than" => [2],
    "less_than" => [2],
    "contains" => [2],
    "is_empty" => [1],
    "and" => :variadic,
    "or" => :variadic,
    "not" => [1],
    "default" => [2],
    "days_between" => [2],
    "year" => [1],
    "format_date" => [2]
  }

  # Document scalars a formula may reference by bare name. `body` is the block
  # tree's plain text; the rest are attributes every content resource declares
  # (a resource without one simply resolves it blank).
  @document_refs ~w(title slug locale excerpt body seo_title seo_description seo_keywords)

  # Guards against a runaway template — these are hand-written by admins, and
  # a formula this long is a paste accident, not a computation.
  @max_length 2_000
  # Cap on a derived *value*. `@max_length` bounds the formula, not its output,
  # and a variadic `concat` can amplify the body ~400x — into jsonb, into every
  # version row, and into the fired artifact.
  @max_output 64_000
  # Largest integer that survives conversion to a double.
  @max_float 1.0e308

  @doc "The function names a template may call."
  @spec functions() :: [String.t()]
  def functions, do: @functions |> Map.keys() |> Enum.sort()

  @doc """
  Every callable function with the wording the formula builder shows: its
  `signature`, a one-line `summary`, and a `category` (`:text`, `:numbers`,
  `:logic`, `:dates`), in the order the builder lists them. The arities come
  from the allowlist itself, so the builder can't offer a call the parser
  refuses.
  """
  @spec catalog() :: [
          %{
            name: String.t(),
            arities: [non_neg_integer()] | :variadic,
            category: atom(),
            signature: String.t(),
            summary: String.t()
          }
        ]
  def catalog do
    [
      entry("word_count", :text, "word_count(text)", gettext("How many words the text has.")),
      entry(
        "char_count",
        :text,
        "char_count(text)",
        gettext("How many characters the text has.")
      ),
      entry(
        "reading_time",
        :text,
        "reading_time(text, words_per_minute?)",
        gettext("Whole minutes it takes to read the text.")
      ),
      entry(
        "slugify",
        :text,
        "slugify(text)",
        gettext("The text as a URL-safe slug: \"Hello World\" → hello-world.")
      ),
      entry("upcase", :text, "upcase(text)", gettext("The text in CAPITALS.")),
      entry("downcase", :text, "downcase(text)", gettext("The text in lower case.")),
      entry(
        "capitalize",
        :text,
        "capitalize(text)",
        gettext("The text with its first letter capitalized.")
      ),
      entry("trim", :text, "trim(text)", gettext("The text without leading or trailing spaces.")),
      entry(
        "truncate",
        :text,
        "truncate(text, length)",
        gettext("The text cut to a number of characters, with … when it was cut.")
      ),
      entry(
        "replace",
        :text,
        "replace(text, find, replacement)",
        gettext("The text with every occurrence of find replaced.")
      ),
      entry(
        "concat",
        :text,
        "concat(a, b, …)",
        gettext("The values joined together with nothing between them.")
      ),
      entry(
        "join",
        :text,
        "join(separator, a, b, …)",
        gettext("The values that aren't empty, joined by the separator.")
      ),
      entry(
        "sum",
        :numbers,
        "sum(a, b, …)",
        gettext("The values added up. Values that aren't numbers are skipped.")
      ),
      entry("subtract", :numbers, "subtract(a, b)", gettext("a minus b.")),
      entry("product", :numbers, "product(a, b, …)", gettext("The values multiplied together.")),
      entry("divide", :numbers, "divide(a, b)", gettext("a divided by b. Empty when b is zero.")),
      entry(
        "round",
        :numbers,
        "round(number, decimals?)",
        gettext("The number rounded, to a whole number or to some decimal places.")
      ),
      entry("min", :numbers, "min(a, b, …)", gettext("The smallest of the numbers.")),
      entry("max", :numbers, "max(a, b, …)", gettext("The largest of the numbers.")),
      entry(
        "if",
        :logic,
        "if(condition, then, otherwise?)",
        gettext("then when the condition holds, otherwise the third value (or empty).")
      ),
      entry(
        "equals",
        :logic,
        "equals(a, b)",
        gettext("Whether a and b are the same. Text is compared ignoring case.")
      ),
      entry("greater_than", :logic, "greater_than(a, b)", gettext("Whether a is more than b.")),
      entry("less_than", :logic, "less_than(a, b)", gettext("Whether a is less than b.")),
      entry(
        "contains",
        :logic,
        "contains(text, part)",
        gettext("Whether the text contains part, ignoring case.")
      ),
      entry("is_empty", :logic, "is_empty(value)", gettext("Whether the value is empty.")),
      entry("and", :logic, "and(a, b, …)", gettext("Whether every condition holds.")),
      entry("or", :logic, "or(a, b, …)", gettext("Whether at least one condition holds.")),
      entry("not", :logic, "not(condition)", gettext("The opposite of the condition.")),
      entry(
        "default",
        :logic,
        "default(value, fallback)",
        gettext("The value, or the fallback when the value is empty.")
      ),
      entry(
        "days_between",
        :dates,
        "days_between(start, end)",
        gettext("Days from the start date to the end date.")
      ),
      entry("year", :dates, "year(date)", gettext("The year of a date.")),
      entry(
        "format_date",
        :dates,
        "format_date(date, pattern)",
        gettext("The date written out: \"%B %-d, %Y\" → October 17, 2026.")
      )
    ]
  end

  defp entry(name, category, signature, summary),
    do: %{
      name: name,
      arities: Map.fetch!(@functions, name),
      category: category,
      signature: signature,
      summary: summary
    }

  @doc "The document scalars a template may reference by bare name."
  @spec document_refs() :: [String.t()]
  def document_refs, do: @document_refs

  @doc """
  Parse a template string. Returns the compiled form, or a human message naming
  what's wrong — the message is shown to the admin defining the field.
  """
  @spec parse(String.t() | nil) :: {:ok, template()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    # Trim first: the whole-template-is-one-expression rule below is defined on
    # the trimmed text, and without this a single trailing space silently
    # demotes `{{ word_count(body) }}` from an integer to a string.
    trimmed = String.trim(source)

    cond do
      trimmed == "" -> {:error, "can't be blank"}
      String.length(trimmed) > @max_length -> {:error, "is too long"}
      true -> trimmed |> segments() |> compile([])
    end
  end

  def parse(_source), do: {:error, "can't be blank"}

  @doc """
  Evaluate a template (parsed or raw) against a context.

  The context is a map with `:document` (string-keyed scalars, including
  `"body"`) and `:fields` (the record's other custom-field values, string-keyed).
  Returns a JSON-native value, or `nil` when the result is blank.
  """
  @spec evaluate(template() | String.t(), map()) :: term()
  # The rescue wraps **parsing as well as evaluation**. Both run on the content
  # write path against admin-authored formulas, and a bug in either must not be
  # the reason a document can't be saved — so a raise anywhere below blanks the
  # value and leaves a trail instead of propagating.
  def evaluate(source, context) do
    case evaluate_checked(source, context) do
      {:ok, value} ->
        value

      {:error, {:parse, _message}} ->
        nil

      {:error, {:raised, message}} ->
        Logger.warning("computed field evaluation failed: #{message}")
        nil
    end
  end

  @doc """
  `evaluate/2`, but saying *why* there is no value: `{:error, {:parse,
  message}}` for a template that doesn't parse, `{:error, {:raised, message}}`
  for one that parses and then fails on this document (a date pattern asking a
  date for its hour). The formula builder's preview shows either instead of
  calling the field empty; the write and fire paths go through `evaluate/2`,
  which blanks both.
  """
  @spec evaluate_checked(template() | String.t(), map()) ::
          {:ok, term()} | {:error, {:parse | :raised, String.t()}}
  def evaluate_checked(source, context) do
    case template(source) do
      {:ok, template} -> {:ok, run(template, context)}
      {:error, message} -> {:error, {:parse, message}}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  @doc """
  The custom-field names a template reads, in first-mention order: every
  `field.<name>`, and every bare name that isn't a document scalar. A template
  that doesn't parse reads nothing.
  """
  @spec references(template() | String.t() | nil) :: [String.t()]
  def references(source) do
    case template(source) do
      {:ok, template} ->
        template
        |> Enum.flat_map(fn
          {:expr, ast} -> refs(ast)
          {:text, _text} -> []
        end)
        |> Enum.uniq()

      {:error, _message} ->
        []
    end
  end

  defp refs({:ref, "field." <> name}), do: [name]
  defp refs({:ref, name}) when name in @document_refs, do: []
  defp refs({:ref, name}), do: [name]
  defp refs({:call, _name, args}), do: Enum.flat_map(args, &refs/1)
  defp refs({:lit, _value}), do: []

  @typedoc "A computed field definition, as far as ordering is concerned."
  @type definition :: %{
          required(:name) => String.t(),
          required(:compute) => String.t() | template() | nil
        }

  @doc """
  Computed `definitions` in dependency order: a field comes after every other
  field in the list its formula references. Fields that don't depend on each
  other keep their given order. Fields on a cycle — and any that read one —
  come last, in their given order (see "Computed fields feeding each other").
  """
  @spec order([definition]) :: [definition]
  def order(definitions), do: settle(definitions, dependencies(definitions), %{}, [])

  # Take the first pending field whose dependencies are all settled, until none
  # is: what is left then is stuck on a cycle. Quadratic, over a type's handful
  # of computed fields.
  #
  # The sets threaded through these recursive helpers (`done` here, `seen` and
  # `reached` below) are plain maps rather than MapSets: OTP 29's dialyzer
  # loses MapSet's opacity through a recursive accumulator and flags
  # `call_without_opaque`, and `:sets` v2 is this same shape underneath.
  defp settle(pending, deps, done, acc) do
    case Enum.find(pending, fn d -> Enum.all?(Map.fetch!(deps, d.name), &is_map_key(done, &1)) end) do
      nil ->
        Enum.reverse(acc) ++ pending

      next ->
        settle(List.delete(pending, next), deps, Map.put(done, next.name, []), [next | acc])
    end
  end

  # name → the names of the *other* listed computed fields its formula reads.
  # A self-reference is not a dependency for ordering (there's nothing to wait
  # for); `cycle/2` reports it.
  defp dependencies(definitions) do
    names = Enum.map(definitions, & &1.name)

    Map.new(definitions, fn d ->
      {d.name, d.compute |> references() |> Enum.filter(&(&1 in names and &1 != d.name))}
    end)
  end

  @doc """
  A cycle among computed `definitions`, as the names along it with the first
  repeated at the end (`["a", "b", "a"]`, or `["a", "a"]` for a formula that
  reads itself) — or `nil` when there is none.

  With `through`, only a cycle passing through that field counts: defining one
  field must not be refused over a cycle elsewhere that it takes no part in.
  """
  @spec cycle([definition], String.t() | nil) :: [String.t()] | nil
  def cycle(definitions, through \\ nil) do
    names = Enum.map(definitions, & &1.name)

    graph =
      Map.new(definitions, fn d ->
        {d.name, d.compute |> references() |> Enum.filter(&(&1 in names))}
      end)

    starts = if through, do: [through], else: Enum.map(definitions, & &1.name)

    Enum.find_value(starts, fn start ->
      graph |> search(start, start, [start], %{start => []}) |> elem(0)
    end)
  end

  # Depth-first for a way back to `start`, `path` newest first. `seen` keeps a
  # cycle *elsewhere* from looping the search: each name is entered once.
  defp search(graph, start, name, path, seen) do
    graph
    |> Map.get(name, [])
    |> Enum.reduce_while({nil, seen}, fn next, {nil, seen} ->
      cond do
        next == start -> {:halt, {Enum.reverse([start | path]), seen}}
        is_map_key(seen, next) -> {:cont, {nil, seen}}
        true -> descend(graph, start, next, path, seen)
      end
    end)
  end

  defp descend(graph, start, next, path, seen) do
    case search(graph, start, next, [next | path], Map.put(seen, next, [])) do
      {nil, seen} -> {:cont, {nil, seen}}
      found -> {:halt, found}
    end
  end

  @doc """
  The names of the computed `definitions` that read `name`, directly or
  through another — the fields `name`'s own formula can't reference without
  closing a cycle. The formula builder leaves them out of its value pickers.
  """
  @spec readers([definition], String.t()) :: [String.t()]
  def readers(definitions, name) do
    reads = Map.new(definitions, &{&1.name, references(&1.compute)})

    reads
    |> spread(%{name => []})
    |> Map.delete(name)
    |> Map.keys()
    |> Enum.sort()
  end

  defp spread(reads, reached) do
    grown =
      for {reader, names} <- reads,
          Enum.any?(names, &is_map_key(reached, &1)),
          into: reached,
          do: {reader, []}

    if map_size(grown) == map_size(reached), do: reached, else: spread(reads, grown)
  end

  @doc """
  Evaluate computed `definitions` in `order/1` into `fields`, each against
  `context` with the values derived so far — so a field reading another
  computed field sees its value from this same pass. A blank result leaves the
  key out. The one derivation loop every evaluation site shares.
  """
  @spec derive([definition], map(), map()) :: map()
  def derive(definitions, context, fields) do
    definitions
    |> order()
    |> Enum.reduce(fields, fn definition, acc ->
      case evaluate(definition.compute || "", Map.put(context, :fields, acc)) do
        nil -> acc
        value -> Map.put(acc, definition.name, value)
      end
    end)
  end

  defp template(source) when is_list(source), do: {:ok, source}
  defp template(source), do: parse(source)

  defp run([{:expr, ast}], context), do: ast |> eval(context) |> blank_to_nil() |> bounded()

  # Interpolation. When **every** expression comes out absent, so does the
  # value: the literal text around them is a label for a value, not a value.
  # Without this, `{{ days_between(start, end) }} days` on a record with no
  # dates stores "days", and `Size {{ size }} EU` stores "Size  EU" — junk that
  # search, `custom_filter` and delivery all treat as a real value.
  defp run(template, context) do
    values = for {:expr, ast} <- template, do: eval(ast, context)

    if Enum.all?(values, &absent?/1) do
      nil
    else
      template
      |> Enum.map_reduce(values, fn
        {:text, text}, values -> {text, values}
        {:expr, _ast}, [value | values] -> {stringify(value), values}
      end)
      |> elem(0)
      |> Enum.join()
      |> String.trim()
      |> blank_to_nil()
      |> bounded()
    end
  end

  # No value at all — unlike `blank?/1`, `false` and `0` are values here: a
  # template interpolating an unticked boolean still says so.
  defp absent?(nil), do: true
  defp absent?(value) when is_binary(value), do: String.trim(value) == ""
  defp absent?(value) when is_list(value), do: value == []
  defp absent?(value) when is_map(value), do: map_size(value) == 0
  defp absent?(_value), do: false

  # Backstop on the derived value's size, for the paths `bounded_join/2` doesn't
  # cover (`{{ body }}` on a huge document, interpolation of several fields).
  defp bounded(value) when is_binary(value) do
    if byte_size(value) > @max_output do
      Logger.warning("computed field result exceeded #{@max_output} bytes; blanked")
      nil
    else
      value
    end
  end

  defp bounded(value), do: value

  # What counts as "no value". This must agree with the write path's own
  # `blank?/1` (`Changes.ApplyCustomFields`), because the write stores the
  # result and the fire re-derives it: if the two disagree about a
  # whitespace-only or empty result, the record and its artifact disagree.
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value) when is_map(value),
    do: if(value == %{}, do: nil, else: value)

  defp blank_to_nil(value), do: value

  # --- parsing ---------------------------------------------------------------

  # Split the source into alternating literal text and `{{ … }}` expressions.
  # Literal-only segments that are empty drop out, so `"{{ a }}{{ b }}"` doesn't
  # carry three empty strings around.
  #
  # `Regex.split/3` with `include_captures: true` emits matches and literals
  # interleaved, but a *literal* can also start with `{{` when a brace pair is
  # never closed. Classifying on the `"{{"` prefix alone would then parse that
  # literal as an expression — so `"{{ title"` would silently look exactly like
  # `"{{ title }}"`, and the tail of `"{{ a }}{{ oops"` would vanish from every
  # record. Match the delimiters at both ends instead, and reject anything with
  # a stray opener left in it.
  defp segments(source) do
    ~r/\{\{(.*?)\}\}/s
    |> Regex.split(source, include_captures: true, trim: true)
    |> Enum.map(fn chunk ->
      case Regex.run(~r/\A\{\{(.*)\}\}\z/s, chunk) do
        [_whole, expression] -> {:expr, expression}
        nil -> {:text, chunk}
      end
    end)
  end

  # An unclosed `{{` survives as literal text; it is always a typo, and silently
  # rendering it verbatim would be worse than saying so.
  defp unclosed?(template), do: Enum.any?(template, &unclosed_text?/1)

  defp unclosed_text?({:text, text}), do: String.contains?(text, "{{")
  defp unclosed_text?(_segment), do: false

  defp compile([], acc) do
    template = Enum.reverse(acc)

    cond do
      unclosed?(template) -> {:error, "has a {{ that is never closed"}
      Enum.any?(template, &match?({:expr, _}, &1)) -> {:ok, template}
      true -> {:error, "must contain at least one {{ … }} expression"}
    end
  end

  defp compile([{:text, text} | rest], acc), do: compile(rest, [{:text, text} | acc])

  defp compile([{:expr, source} | rest], acc) do
    with {:ok, tokens} <- tokenize(source),
         {:ok, ast, []} <- parse_expr(tokens) do
      compile(rest, [{:expr, ast} | acc])
    else
      {:ok, _ast, [token | _]} -> {:error, "unexpected #{describe(token)} in #{inspect(source)}"}
      {:error, message} -> {:error, message}
    end
  end

  # --- tokenizer -------------------------------------------------------------

  defp tokenize(source), do: tokenize(String.trim(source), [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<char::utf8, rest::binary>>, acc) when char in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, acc)

  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:open | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:close | acc])
  defp tokenize("," <> rest, acc), do: tokenize(rest, [:comma | acc])

  defp tokenize(<<quote::utf8, rest::binary>>, acc) when quote in [?", ?'] do
    case String.split(rest, <<quote::utf8>>, parts: 2) do
      [string, remainder] -> tokenize(remainder, [{:lit, string} | acc])
      [_unterminated] -> {:error, "has an unterminated string"}
    end
  end

  defp tokenize(<<char::utf8, _rest::binary>> = source, acc) when char in ?0..?9 or char == ?- do
    case Regex.run(~r/\A-?\d+(\.\d+)?/, source) do
      [number | _] ->
        tokenize(binary_part(source, byte_size(number), byte_size(source) - byte_size(number)), [
          {:lit, to_number(number)} | acc
        ])

      nil ->
        {:error, "has an unexpected #{inspect(<<char::utf8>>)}"}
    end
  end

  defp tokenize(<<char::utf8, _rest::binary>> = source, acc)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    [name | _] = Regex.run(~r/\A[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?/, source)

    tokenize(
      binary_part(source, byte_size(name), byte_size(source) - byte_size(name)),
      [{:name, name} | acc]
    )
  end

  defp tokenize(<<char::utf8, _rest::binary>>, _acc),
    do: {:error, "has an unexpected #{inspect(<<char::utf8>>)}"}

  # Fall back to the integer part rather than blowing up on a number nobody can
  # represent — `parse/1` is called directly by the fields admin, so a raise
  # here is a 500 on a form.
  defp to_number(text) do
    case {Integer.parse(text), Kiln.FieldType.parse_float(text)} do
      {{integer, ""}, _} -> integer
      {_, {float, ""}} -> float
      {{integer, _remainder}, _} -> integer
      {:error, _} -> 0
    end
  end

  # --- recursive-descent parser ----------------------------------------------

  defp parse_expr([{:lit, value} | rest]), do: {:ok, {:lit, value}, rest}

  defp parse_expr([{:name, name}, :open | rest]), do: parse_call(name, rest)

  defp parse_expr([{:name, name} | rest]), do: {:ok, {:ref, name}, rest}

  defp parse_expr([]), do: {:error, "is missing an expression"}
  defp parse_expr([token | _rest]), do: {:error, "starts with an unexpected #{describe(token)}"}

  defp parse_call(name, [:close | rest]), do: finish_call(name, [], rest)

  defp parse_call(name, tokens) do
    with {:ok, args, rest} <- parse_args(tokens, []) do
      finish_call(name, args, rest)
    end
  end

  defp parse_args(tokens, acc) do
    with {:ok, ast, rest} <- parse_expr(tokens) do
      case rest do
        [:comma | rest] -> parse_args(rest, [ast | acc])
        [:close | rest] -> {:ok, Enum.reverse([ast | acc]), rest}
        _ -> {:error, "is missing a closing parenthesis"}
      end
    end
  end

  defp finish_call(name, args, rest) do
    case Map.fetch(@functions, name) do
      :error ->
        {:error, "calls unknown function #{name}/#{length(args)}"}

      {:ok, :variadic} when args != [] ->
        {:ok, {:call, name, args}, rest}

      {:ok, :variadic} ->
        {:error, "#{name}() needs at least one argument"}

      {:ok, arities} ->
        if length(args) in arities do
          {:ok, {:call, name, args}, rest}
        else
          {:error,
           "#{name}() takes #{Enum.join(arities, " or ")} argument(s), got #{length(args)}"}
        end
    end
  end

  defp describe(:open), do: "("
  defp describe(:close), do: ")"
  defp describe(:comma), do: ","
  defp describe({:name, name}), do: inspect(name)
  defp describe({:lit, value}), do: inspect(value)

  # --- evaluation ------------------------------------------------------------

  defp eval({:lit, value}, _context), do: value

  defp eval({:ref, "field." <> name}, context), do: field(context, name)

  defp eval({:ref, name}, context) when name in @document_refs do
    context |> Map.get(:document, %{}) |> Map.get(name)
  end

  defp eval({:ref, name}, context), do: field(context, name)

  defp eval({:call, name, args}, context) do
    call(name, Enum.map(args, &eval(&1, context)))
  end

  defp field(context, name), do: context |> Map.get(:fields, %{}) |> Map.get(name)

  # --- the function allowlist ------------------------------------------------

  defp call("word_count", [text]), do: text |> words() |> length()

  defp call("char_count", [text]), do: text |> stringify() |> String.length()

  # The rate comes from `KilnCMS.CMS.Calculations.ReadingTime` rather than a
  # local constant (#492). This used to default to 200 while the calculation used
  # 230 and ignored `:reading_time_wpm` entirely, so a site with both a
  # `reading_time` computed field and the `readingTimeMinutes` API field got two
  # different answers for one document — and setting the config moved only one.
  defp call("reading_time", [text]),
    do: call("reading_time", [text, default_wpm()])

  defp call("reading_time", [text, wpm]) do
    words = text |> words() |> length()

    case number(wpm) do
      {:ok, rate} when rate > 0 and words > 0 -> ceil(words / rate)
      # An empty body reads in no time; a nonsense rate falls back to the
      # default rather than silently yielding nil.
      {:ok, _rate} -> if words > 0, do: ceil(words / default_wpm()), else: 0
      :error -> if words > 0, do: ceil(words / default_wpm()), else: 0
    end
  end

  defp call("slugify", [text]), do: text |> stringify() |> Slug.slugify()
  defp call("upcase", [text]), do: text |> stringify() |> String.upcase()
  defp call("downcase", [text]), do: text |> stringify() |> String.downcase()
  defp call("capitalize", [text]), do: text |> stringify() |> String.capitalize()
  defp call("trim", [text]), do: text |> stringify() |> String.trim()

  defp call("truncate", [text, length]) do
    string = stringify(text)

    case number(length) do
      {:ok, max} when max > 0 ->
        max = trunc(max)
        if String.length(string) > max, do: String.slice(string, 0, max) <> "…", else: string

      _ ->
        string
    end
  end

  defp call("concat", args), do: args |> Enum.map(&stringify/1) |> bounded_join("")

  defp call("join", [separator | args]) do
    args
    |> Enum.map(&stringify/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> bounded_join(stringify(separator))
  end

  defp call("sum", args), do: reduce_numbers(args, &(&1 + &2))
  # Unlike the sum, a product with a missing factor has no answer: price ×
  # (no quantity) is not the price, and `product(divide(part, 0), 100)` is not
  # 100. Every argument must be numeric.
  defp call("product", args) do
    numbers = Enum.map(args, &number/1)

    if Enum.all?(numbers, &match?({:ok, _}, &1)),
      do: numbers |> Enum.map(fn {:ok, n} -> n end) |> Enum.reduce(&(&1 * &2)),
      else: nil
  end

  defp call("min", args), do: reduce_numbers(args, &Kernel.min/2)
  defp call("max", args), do: reduce_numbers(args, &Kernel.max/2)

  defp call("subtract", [a, b]) do
    with {:ok, left} <- number(a), {:ok, right} <- number(b), do: left - right, else: (_ -> nil)
  end

  defp call("divide", [a, b]) do
    with {:ok, left} <- number(a),
         {:ok, right} when right != 0 <- number(b),
         {:ok, left} <- to_float(left),
         {:ok, right} <- to_float(right) do
      left / right
    else
      _ -> nil
    end
  end

  defp call("round", [value]) do
    case number(value) do
      {:ok, number} -> round(number)
      :error -> nil
    end
  end

  defp call("round", [value, precision]) do
    with {:ok, number} <- number(value),
         {:ok, digits} when digits >= 0 <- number(precision),
         {:ok, float} <- to_float(number) do
      Float.round(float, min(trunc(digits), 15))
    else
      # Includes the out-of-double-range case, where `round/1` still works fine
      # on the integer — better than blanking a field over precision.
      _ -> call("round", [value])
    end
  end

  defp call("default", [value, fallback]), do: if(blank?(value), do: fallback, else: value)

  defp call("replace", [text, find, replacement]) do
    case stringify(find) do
      "" -> stringify(text)
      pattern -> bounded_replace(stringify(text), pattern, stringify(replacement))
    end
  end

  defp call("if", [condition, then]), do: call("if", [condition, then, nil])

  defp call("if", [condition, then, otherwise]),
    do: if(truthy?(condition), do: then, else: otherwise)

  defp call("equals", [a, b]), do: compare(a, b) == :eq
  # An ordering needs two values: a blank is neither more nor less than
  # anything, so an unpriced product is not "less than 100".
  defp call("greater_than", [a, b]),
    do: not absent?(a) and not absent?(b) and compare(a, b) == :gt

  defp call("less_than", [a, b]), do: not absent?(a) and not absent?(b) and compare(a, b) == :lt

  defp call("contains", [text, part]) do
    case part |> stringify() |> String.downcase() do
      "" -> false
      needle -> text |> stringify() |> String.downcase() |> String.contains?(needle)
    end
  end

  defp call("is_empty", [value]), do: blank?(value)
  defp call("and", args), do: Enum.all?(args, &truthy?/1)
  defp call("or", args), do: Enum.any?(args, &truthy?/1)
  defp call("not", [value]), do: not truthy?(value)

  defp call("days_between", [start, finish]) do
    with {:ok, from} <- date(start),
         {:ok, to} <- date(finish),
         do: Date.diff(to, from),
         else: (_ -> nil)
  end

  defp call("year", [value]) do
    case date(value) do
      {:ok, date} -> date.year
      :error -> nil
    end
  end

  defp call("format_date", [value, pattern]) do
    case {date(value), stringify(pattern)} do
      {{:ok, date}, ""} -> Date.to_iso8601(date)
      {{:ok, date}, format} -> Calendar.strftime(date, format)
      {:error, _format} -> nil
    end
  end

  # Spreadsheet truthiness: a blank, `false`, zero or the text "false" doesn't
  # hold. A boolean custom field stores a real boolean, but a select or text
  # field holding "false" means the same thing to the admin who wrote the
  # condition.
  defp truthy?(value) when value in [nil, false, 0, [], %{}], do: false
  defp truthy?(value) when is_float(value), do: value != 0.0

  defp truthy?(value) when is_binary(value),
    do: String.trim(value) |> String.downcase() |> then(&(&1 not in ["", "false"]))

  defp truthy?(_value), do: true

  # Numbers compare as numbers when both sides are numeric ("10" > "9");
  # anything else compares as trimmed, case-folded text, which also orders ISO
  # dates correctly. A blank on either side is never equal to a non-blank (and
  # `greater_than`/`less_than` refuse a blank before comparing at all).
  defp compare(a, b) do
    case {number(a), number(b)} do
      {{:ok, left}, {:ok, right}} ->
        cond do
          left == right -> :eq
          left > right -> :gt
          true -> :lt
        end

      _text ->
        left = a |> stringify() |> String.trim() |> String.downcase()
        right = b |> stringify() |> String.trim() |> String.downcase()

        cond do
          left == right -> :eq
          left > right -> :gt
          true -> :lt
        end
    end
  end

  # A date or datetime custom field stores ISO 8601 text; the date part is the
  # first ten characters of either.
  defp date(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 10) |> Date.from_iso8601() do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp date(_value), do: :error

  # `sum`/`min`/`max` ignore arguments that aren't numeric — an unset optional
  # price should not blank out the total. (`product` doesn't: see its clause.)
  defp reduce_numbers(args, fun) do
    case Enum.flat_map(args, &numeric/1) do
      [] -> nil
      numbers -> Enum.reduce(numbers, fun)
    end
  end

  defp numeric(value) do
    case number(value) do
      {:ok, number} -> [number]
      :error -> []
    end
  end

  defp number(value) when is_number(value), do: {:ok, value}

  defp number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Kiln.FieldType.parse_float(trimmed) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp number(_value), do: :error

  # Integers are arbitrary-precision on the BEAM but floats are not, so
  # converting one that overflows a double raises ArithmeticError. Callers that
  # need float maths check first and fall back rather than blanking the field.
  defp to_float(number) when is_float(number), do: {:ok, number}

  defp to_float(number) when is_integer(number) do
    if number >= -@max_float and number <= @max_float, do: {:ok, number / 1}, else: :error
  end

  # `concat`/`join` are variadic over document values, so a formula that fits
  # inside `@max_length` can still ask for ~400 copies of the body. Stop
  # building once the result passes the cap: the value is stored in jsonb, in
  # every PaperTrail version, and in the fired artifact, so an unbounded one is
  # a memory-exhaustion lever for anyone who can define a field.
  defp bounded_join(parts, separator) do
    parts
    |> Enum.reduce_while([], fn part, acc ->
      acc = if acc == [], do: [part], else: [part, separator | acc]

      if IO.iodata_length(acc) > @max_output, do: {:halt, :too_large}, else: {:cont, acc}
    end)
    |> case do
      :too_large -> nil
      acc -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp default_wpm, do: KilnCMS.CMS.Calculations.ReadingTime.words_per_minute()

  defp words(text), do: text |> stringify() |> String.split(~r/\s+/u, trim: true)

  # A list or map (a gallery, a reference, a multi-select, a geolocation) is
  # blank only when it holds nothing — `stringify/1` renders every one as "",
  # which would make `is_empty(gallery)` true on a document full of images.
  defp blank?(value) when is_list(value), do: value == []
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(value), do: value in [nil, false] or String.trim(stringify(value)) == ""

  # `replace` can multiply its input (`replace(body, " ", body)` is quadratic in
  # the body), so the result's size is worked out from the match count before
  # anything is built, rather than built and then measured by `bounded/1`.
  defp bounded_replace(text, pattern, replacement) do
    matches = text |> :binary.matches(pattern) |> length()
    size = byte_size(text) + matches * (byte_size(replacement) - byte_size(pattern))

    if size > @max_output do
      Logger.warning("computed field replace() would exceed #{@max_output} bytes; blanked")
      nil
    else
      String.replace(text, pattern, replacement)
    end
  end

  # Stringification for interpolation: JSON-native values only, so a map/list
  # (a geolocation, a multi-select) renders as nothing rather than leaking an
  # Elixir inspect into delivered content.
  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp stringify(_value), do: ""
end
