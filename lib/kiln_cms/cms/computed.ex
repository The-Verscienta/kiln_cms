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
  | `sum/product/min/max(a, b, …)` | over the numeric arguments (non-numbers ignored) |
  | `subtract(a, b)` / `divide(a, b)` | `nil` if either side isn't numeric (or on divide by zero) |
  | `round(n)` / `round(n, precision)` | `n` rounded |
  | `default(a, b)` | `a` unless blank, else `b` |

  Evaluation is **total**: every function returns a value or `nil`, and
  `evaluate/2` never raises — a computed field can't make a document
  unsaveable.
  """
  require Logger

  alias KilnCMS.Slug

  @typedoc "A parsed template: literal text and expression segments, in order."
  @opaque template :: [{:text, String.t()} | {:expr, term()}]

  # Allowed function names → allowed arities (`:variadic` for any count ≥ 1).
  # The allowlist *is* the sandbox: a name that isn't here fails to parse.
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
    "concat" => :variadic,
    "join" => :variadic,
    "sum" => :variadic,
    "product" => :variadic,
    "min" => :variadic,
    "max" => :variadic,
    "subtract" => [2],
    "divide" => [2],
    "round" => [1, 2],
    "default" => [2]
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
    case template(source) do
      {:ok, template} -> run(template, context)
      :error -> nil
    end
  rescue
    error ->
      Logger.warning("computed field evaluation failed: #{Exception.message(error)}")
      nil
  end

  defp template(source) when is_list(source), do: {:ok, source}

  defp template(source) do
    case parse(source) do
      {:ok, template} -> {:ok, template}
      {:error, _message} -> :error
    end
  end

  defp run([{:expr, ast}], context), do: ast |> eval(context) |> blank_to_nil() |> bounded()

  defp run(template, context) do
    template
    |> Enum.map_join("", fn
      {:text, text} -> text
      {:expr, ast} -> ast |> eval(context) |> stringify()
    end)
    |> String.trim()
    |> blank_to_nil()
    |> bounded()
  end

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
    case {Integer.parse(text), safe_float(text)} do
      {{integer, ""}, _} -> integer
      {_, {float, ""}} -> float
      {{integer, _remainder}, _} -> integer
      {:error, _} -> 0
    end
  end

  @doc false
  # `Float.parse/1` is not total, and *how* it fails is version-dependent: for a
  # literal that overflows a double it returns the bare atom `:error` on Elixir
  # 1.20 but **raises** ArgumentError from `:erlang.list_to_float/1` on 1.19
  # (this project's pinned toolchain — see `.tool-versions`). Neither is safe to
  # pattern-match on directly, so normalize both into `:error` here.
  def safe_float(text) do
    Float.parse(text)
  rescue
    ArgumentError -> :error
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
  defp call("product", args), do: reduce_numbers(args, &(&1 * &2))
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

  # `sum`/`product`/`min`/`max` ignore arguments that aren't numeric — an unset
  # optional price should not blank out the total.
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
        case safe_float(trimmed) do
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

  defp blank?(value), do: value in [nil, false] or String.trim(stringify(value)) == ""

  # Stringification for interpolation: JSON-native values only, so a map/list
  # (a geolocation, a multi-select) renders as nothing rather than leaking an
  # Elixir inspect into delivered content.
  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp stringify(_value), do: ""
end
