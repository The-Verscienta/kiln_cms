defmodule KilnCMS.CMS.Computed.Recipes do
  @moduledoc """
  Fill-in-the-blank **recipes** for computed fields — the no-code half of the
  formula builder (`KilnCMSWeb.ComputedBuilderComponents`).

  A recipe is a common computation ("reading time of the body", "if a field is
  empty, show this text") with a few named **slots**: a value picked from the
  document or another field, a piece of text, a number, a comparison. An admin
  fills the slots; `build/2` writes the formula. Nothing new is stored — the
  result is an ordinary `compute` template (`KilnCMS.CMS.Computed`), evaluated
  exactly like a hand-written one, so a recipe can't do anything a formula
  can't.

  Going the other way, `recognize/1` reads a stored formula back into its
  recipe and slots, so a field built from a recipe reopens in the recipe view.
  Recognition is checked by **round trip**: a formula counts as a recipe only
  when building that recipe from the recognized slots parses to the very same
  template. A formula an admin has since edited by hand — an extra function, a
  different spacing around literal text — is therefore never squeezed into a
  recipe that would rewrite it; it opens in the formula view instead.

  ## Slot kinds

    * `:value` — a reference, as written in a formula: a document value
      (`"body"`, `"title"`) or a custom field (`"price"`, or `"field.title"`
      for a field whose name a document value already takes);
    * `:text` — literal text, quoted into the formula;
    * `:number` — a number;
    * `:operator` — one of `operators/0`.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.CMS.Computed

  @type slot :: %{
          key: String.t(),
          label: String.t(),
          kind: :value | :text | :number | :operator,
          required?: boolean(),
          default: String.t()
        }

  @type recipe :: %{id: String.t(), label: String.t(), summary: String.t(), slots: [slot()]}

  @operators ~w(equals greater_than less_than contains is_empty)

  # The identifier shape the tokenizer accepts (`Computed`): a name, optionally
  # `field.` qualified. A slot value is spliced into the formula, so anything
  # else is refused rather than allowed to change the expression's structure.
  @reference ~r/\A[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?\z/

  @doc "Every recipe, in the order the builder offers them."
  @spec all() :: [recipe()]
  def all do
    [
      recipe(
        "reading_time",
        gettext("Reading time"),
        gettext("Minutes it takes to read a text."),
        [
          value("source", gettext("Text to read"), "body"),
          text("suffix", gettext("Shown after the number"), gettext("min read"))
        ]
      ),
      recipe("word_count", gettext("Word count"), gettext("How many words a text has."), [
        value("source", gettext("Text to count"), "body"),
        text("suffix", gettext("Shown after the number"), "")
      ]),
      recipe(
        "label",
        gettext("Value with a label"),
        gettext("A value with text before or after it, like “Size 42 EU”."),
        [
          text("prefix", gettext("Text before"), ""),
          value("value", gettext("Value"), ""),
          text("suffix", gettext("Text after"), "")
        ]
      ),
      recipe(
        "combine",
        gettext("Combine values"),
        gettext("Two or three values joined into one, skipping any that are empty."),
        [
          value("first", gettext("First value"), ""),
          value("second", gettext("Second value"), ""),
          value("third", gettext("Third value (optional)"), "", false),
          text("separator", gettext("Between them"), " ")
        ]
      ),
      recipe("slug", gettext("URL slug"), gettext("A value turned into a URL-safe slug."), [
        value("source", gettext("Make a slug from"), "title")
      ]),
      recipe(
        "excerpt",
        gettext("Shortened text"),
        gettext("The start of a text, cut to a length."),
        [
          value("source", gettext("Text"), "body"),
          number("length", gettext("Characters"), "160")
        ]
      ),
      recipe(
        "fallback",
        gettext("First value that isn't empty"),
        gettext("A value, or a backup value when it's empty."),
        [
          value("primary", gettext("Use this value"), ""),
          value("fallback", gettext("When it's empty, use"), "")
        ]
      ),
      recipe("total", gettext("Total"), gettext("Numbers added up."), [
        value("first", gettext("First number"), ""),
        value("second", gettext("Second number"), ""),
        value("third", gettext("Third number (optional)"), "", false),
        value("fourth", gettext("Fourth number (optional)"), "", false)
      ]),
      recipe(
        "multiply",
        gettext("Multiply"),
        gettext("One number times another, like price × quantity."),
        [
          value("first", gettext("Number"), ""),
          value("second", gettext("Times"), "")
        ]
      ),
      recipe(
        "percentage",
        gettext("Percentage"),
        gettext("One number as a percentage of another."),
        [
          value("part", gettext("Part"), ""),
          value("whole", gettext("Out of"), ""),
          number("decimals", gettext("Decimal places"), "0")
        ]
      ),
      recipe(
        "conditional",
        gettext("If … then …"),
        gettext("Show one text when a condition holds and another when it doesn't."),
        [
          value("value", gettext("When"), ""),
          %{
            key: "operator",
            label: gettext("Condition"),
            kind: :operator,
            required?: true,
            default: "equals"
          },
          text("compare", gettext("Compared with"), "", false),
          text("then", gettext("Then show"), "", true),
          text("otherwise", gettext("Otherwise show"), "")
        ]
      ),
      recipe(
        "days_between",
        gettext("Days between dates"),
        gettext("How many days from one date to another."),
        [
          value("start", gettext("From date"), ""),
          value("finish", gettext("To date"), ""),
          text("suffix", gettext("Shown after the number"), gettext("days"))
        ]
      ),
      recipe(
        "days_until",
        gettext("Days until a date"),
        gettext(
          "How many days are left until a date — negative once it has passed. Refreshed daily."
        ),
        [
          value("date", gettext("Date"), ""),
          text("suffix", gettext("Shown after the number"), gettext("days"))
        ]
      ),
      recipe(
        "age",
        gettext("Age in years"),
        gettext("Whole years since a date, like a person's age. Refreshed daily."),
        [
          value("date", gettext("Since date"), ""),
          text("suffix", gettext("Shown after the number"), "")
        ]
      )
    ]
  end

  @doc "The recipe with `id`, or nil."
  @spec get(String.t() | nil) :: recipe() | nil
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The comparison operators a `:operator` slot offers, with their wording."
  @spec operators() :: [{String.t(), String.t()}]
  def operators do
    [
      {"equals", gettext("is")},
      {"greater_than", gettext("is more than")},
      {"less_than", gettext("is less than")},
      {"contains", gettext("contains")},
      {"is_empty", gettext("is empty")}
    ]
  end

  @doc "A recipe's slots filled with their defaults."
  @spec defaults(String.t()) :: %{String.t() => String.t()}
  def defaults(id) do
    case get(id) do
      nil -> %{}
      recipe -> Map.new(recipe.slots, &{&1.key, &1.default})
    end
  end

  @doc """
  Write the formula for a recipe from its slot values (string-keyed, as a form
  submits them). Returns a human message naming the slot that's wrong.
  """
  @spec build(String.t() | nil, map()) :: {:ok, String.t()} | {:error, String.t()}
  def build(id, params) when is_map(params) do
    case get(id) do
      nil ->
        {:error, gettext("Pick a recipe.")}

      recipe ->
        params = Map.new(recipe.slots, &{&1.key, slot_value(params, &1)})

        with :ok <- check_required(recipe, params) do
          formula(id, params)
        end
    end
  catch
    {:slot, message} -> {:error, message}
  end

  def build(_id, _params), do: {:error, gettext("Pick a recipe.")}

  @doc """
  The prompt for the first required slot still empty, or nil when every one is
  filled. The builder shows this as a prompt rather than an error: a recipe
  just picked has empty blanks, and that isn't a mistake yet.
  """
  @spec missing(String.t() | nil, map()) :: String.t() | nil
  def missing(id, params) when is_map(params) do
    case get(id) do
      nil ->
        nil

      recipe ->
        case check_required(recipe, Map.new(recipe.slots, &{&1.key, slot_value(params, &1)})) do
          :ok -> nil
          {:error, message} -> message
        end
    end
  end

  def missing(_id, _params), do: nil

  @doc """
  The recipe a formula was built from, with its slot values — or `:error` when
  it isn't exactly a recipe's output (see the moduledoc on round trips).
  """
  @spec recognize(String.t() | nil) :: {:ok, String.t(), map()} | :error
  def recognize(formula) when is_binary(formula) do
    with {:ok, template} <- Computed.parse(formula),
         {:ok, id, params} <- match(template),
         {:ok, rebuilt} <- build(id, params),
         {:ok, ^template} <- Computed.parse(rebuilt) do
      {:ok, id, Map.merge(defaults(id), params)}
    else
      _ -> :error
    end
  end

  def recognize(_formula), do: :error

  # --- definitions -----------------------------------------------------------

  defp recipe(id, label, summary, slots),
    do: %{id: id, label: label, summary: summary, slots: slots}

  defp value(key, label, default, required? \\ true),
    do: %{key: key, label: label, kind: :value, required?: required?, default: default}

  defp text(key, label, default, required? \\ false),
    do: %{key: key, label: label, kind: :text, required?: required?, default: default}

  defp number(key, label, default),
    do: %{key: key, label: label, kind: :number, required?: true, default: default}

  # Text slots keep their spacing (a separator of " " is the point); the rest
  # are trimmed.
  defp slot_value(params, %{key: key, kind: :text}), do: to_string(Map.get(params, key) || "")

  defp slot_value(params, %{key: key}),
    do: params |> Map.get(key) |> Kernel.||("") |> to_string() |> String.trim()

  defp check_required(%{id: "conditional"}, %{"operator" => op, "compare" => compare})
       when op != "is_empty" and compare == "",
       do: {:error, gettext("Fill in what to compare with.")}

  defp check_required(recipe, params) do
    case Enum.find(recipe.slots, &(&1.required? and Map.fetch!(params, &1.key) == "")) do
      nil ->
        :ok

      %{kind: :value, label: label} ->
        {:error, gettext("Pick a value for “%{slot}”.", slot: label)}

      %{label: label} ->
        {:error, gettext("Fill in “%{slot}”.", slot: label)}
    end
  end

  # --- building --------------------------------------------------------------

  defp formula("reading_time", p),
    do: {:ok, call_with_suffix("reading_time", [ref(p["source"])], p["suffix"])}

  defp formula("word_count", p),
    do: {:ok, call_with_suffix("word_count", [ref(p["source"])], p["suffix"])}

  defp formula("days_between", p),
    do: {:ok, call_with_suffix("days_between", [ref(p["start"]), ref(p["finish"])], p["suffix"])}

  defp formula("days_until", p),
    do: {:ok, call_with_suffix("days_between", ["today()", ref(p["date"])], p["suffix"])}

  defp formula("age", p),
    do: {:ok, call_with_suffix("years_between", [ref(p["date"]), "today()"], p["suffix"])}

  defp formula("label", p) do
    {:ok,
     [segment(p["prefix"]), "{{ #{ref(p["value"])} }}", segment(p["suffix"])]
     |> Enum.reject(&(&1 == ""))
     |> Enum.join(" ")}
  end

  defp formula("combine", p) do
    refs = refs(p, ~w(first second third))
    {:ok, "{{ join(#{Enum.join([lit(p["separator"]) | refs], ", ")}) }}"}
  end

  defp formula("slug", p), do: {:ok, "{{ slugify(#{ref(p["source"])}) }}"}

  defp formula("excerpt", p) do
    {:ok, "{{ truncate(#{ref(p["source"])}, #{whole(p["length"], 1, 100_000)}) }}"}
  end

  defp formula("fallback", p),
    do: {:ok, "{{ default(#{ref(p["primary"])}, #{ref(p["fallback"])}) }}"}

  defp formula("total", p),
    do: {:ok, "{{ sum(#{Enum.join(refs(p, ~w(first second third fourth)), ", ")}) }}"}

  defp formula("multiply", p), do: {:ok, "{{ product(#{ref(p["first"])}, #{ref(p["second"])}) }}"}

  defp formula("percentage", p) do
    ratio = "product(divide(#{ref(p["part"])}, #{ref(p["whole"])}), 100)"

    case whole(p["decimals"], 0, 6) do
      0 -> {:ok, "{{ round(#{ratio}) }}%"}
      decimals -> {:ok, "{{ round(#{ratio}, #{decimals}) }}%"}
    end
  end

  defp formula("conditional", p) do
    condition =
      case p["operator"] do
        "is_empty" -> "is_empty(#{ref(p["value"])})"
        op when op in @operators -> "#{op}(#{ref(p["value"])}, #{operand(p["compare"])})"
        _other -> throw({:slot, gettext("Pick a condition.")})
      end

    branches =
      Enum.reject([lit(p["then"]), p["otherwise"] != "" && lit(p["otherwise"])], &(&1 == false))

    {:ok, "{{ if(#{Enum.join([condition | branches], ", ")}) }}"}
  end

  defp call_with_suffix(name, args, suffix) do
    case segment(suffix) do
      "" -> "{{ #{name}(#{Enum.join(args, ", ")}) }}"
      text -> "{{ #{name}(#{Enum.join(args, ", ")}) }} #{text}"
    end
  end

  # The optional trailing value slots, in order, without the blank ones.
  defp refs(p, keys), do: for(key <- keys, p[key] != "", do: ref(p[key]))

  defp ref(value) do
    if Regex.match?(@reference, value),
      do: value,
      else: throw({:slot, gettext("“%{value}” isn't a value a formula can use.", value: value)})
  end

  # Literal text outside the braces. A `{{` or `}}` in it would open or close
  # an expression of its own.
  defp segment(text) do
    text = String.trim(text)

    if String.contains?(text, ["{{", "}}"]),
      do: throw({:slot, gettext("Text can't contain {{ or }}.")}),
      else: text
  end

  # A quoted string literal. The tokenizer has no escapes, so the quote mark is
  # whichever one the text doesn't contain; braces would end the expression.
  defp lit(text) do
    cond do
      String.contains?(text, ["{{", "}}"]) ->
        throw({:slot, gettext("Text can't contain {{ or }}.")})

      not String.contains?(text, "\"") ->
        "\"" <> text <> "\""

      not String.contains?(text, "'") ->
        "'" <> text <> "'"

      true ->
        throw({:slot, gettext("Text can't contain both \" and ' quote marks.")})
    end
  end

  # A comparison operand: a number stays a number, so `greater_than(price,
  # 100)` compares numerically; anything else is quoted text.
  defp operand(text) do
    text = String.trim(text)
    if Regex.match?(~r/\A-?\d+(\.\d+)?\z/, text), do: text, else: lit(text)
  end

  defp whole(text, min, max) do
    case Integer.parse(text) do
      {n, ""} when n >= min and n <= max ->
        n

      _ ->
        throw({:slot, gettext("Use a whole number from %{min} to %{max}.", min: min, max: max)})
    end
  end

  # --- recognizing -----------------------------------------------------------

  defp match([{:expr, {:call, name, [{:ref, source}]}} | suffix])
       when name in ["reading_time", "word_count"] do
    with {:ok, suffix} <- suffix(suffix),
         do: {:ok, name, %{"source" => source, "suffix" => suffix}}
  end

  defp match([{:expr, {:call, "days_between", [{:call, "today", []}, {:ref, date}]}} | suffix]) do
    with {:ok, suffix} <- suffix(suffix),
         do: {:ok, "days_until", %{"date" => date, "suffix" => suffix}}
  end

  defp match([{:expr, {:call, "years_between", [{:ref, date}, {:call, "today", []}]}} | suffix]) do
    with {:ok, suffix} <- suffix(suffix),
         do: {:ok, "age", %{"date" => date, "suffix" => suffix}}
  end

  defp match([{:expr, {:call, "days_between", [{:ref, start}, {:ref, finish}]}} | suffix]) do
    with {:ok, suffix} <- suffix(suffix),
         do: {:ok, "days_between", %{"start" => start, "finish" => finish, "suffix" => suffix}}
  end

  defp match([{:expr, {:call, "join", [{:lit, separator} | refs]}}])
       when is_binary(separator) and length(refs) in 2..3 do
    with {:ok, names} <- ref_names(refs) do
      {:ok, "combine", Map.put(slots(~w(first second third), names), "separator", separator)}
    end
  end

  defp match([{:expr, {:call, "slugify", [{:ref, source}]}}]),
    do: {:ok, "slug", %{"source" => source}}

  defp match([{:expr, {:call, "truncate", [{:ref, source}, {:lit, length}]}}])
       when is_integer(length),
       do: {:ok, "excerpt", %{"source" => source, "length" => to_string(length)}}

  defp match([{:expr, {:call, "default", [{:ref, primary}, {:ref, fallback}]}}]),
    do: {:ok, "fallback", %{"primary" => primary, "fallback" => fallback}}

  defp match([{:expr, {:call, "sum", refs}}]) when length(refs) in 2..4 do
    with {:ok, names} <- ref_names(refs),
         do: {:ok, "total", slots(~w(first second third fourth), names)}
  end

  defp match([{:expr, {:call, "product", [{:ref, first}, {:ref, second}]}}]),
    do: {:ok, "multiply", %{"first" => first, "second" => second}}

  defp match([{:expr, {:call, "round", [ratio | decimals]}}, {:text, "%"}]) do
    with {:call, "product", [{:call, "divide", [{:ref, part}, {:ref, whole}]}, {:lit, 100}]} <-
           ratio,
         {:ok, decimals} <- decimals(decimals) do
      {:ok, "percentage", %{"part" => part, "whole" => whole, "decimals" => decimals}}
    else
      _ -> :error
    end
  end

  defp match([{:expr, {:call, "if", [condition, {:lit, then} | otherwise]}}])
       when is_binary(then) do
    with {:ok, slots} <- condition(condition),
         {:ok, otherwise} <- otherwise(otherwise) do
      {:ok, "conditional", Map.merge(slots, %{"then" => then, "otherwise" => otherwise})}
    end
  end

  defp match(template) do
    case Enum.split_with(template, &match?({:expr, _}, &1)) do
      {[{:expr, {:ref, value}}], _texts} -> label(template, value)
      _other -> :error
    end
  end

  defp label(template, value) do
    case template do
      [{:expr, _}] ->
        {:ok, "label", %{"prefix" => "", "value" => value, "suffix" => ""}}

      [{:text, p}, {:expr, _}] ->
        {:ok, "label", %{"prefix" => String.trim(p), "value" => value, "suffix" => ""}}

      [{:expr, _}, {:text, s}] ->
        {:ok, "label", %{"prefix" => "", "value" => value, "suffix" => String.trim(s)}}

      [{:text, p}, {:expr, _}, {:text, s}] ->
        {:ok, "label",
         %{"prefix" => String.trim(p), "value" => value, "suffix" => String.trim(s)}}

      _other ->
        :error
    end
  end

  defp suffix([]), do: {:ok, ""}
  defp suffix([{:text, text}]), do: {:ok, String.trim(text)}
  defp suffix(_rest), do: :error

  defp decimals([]), do: {:ok, "0"}
  defp decimals([{:lit, n}]) when is_integer(n), do: {:ok, to_string(n)}
  defp decimals(_other), do: :error

  defp condition({:call, "is_empty", [{:ref, value}]}),
    do: {:ok, %{"value" => value, "operator" => "is_empty", "compare" => ""}}

  defp condition({:call, op, [{:ref, value}, {:lit, compare}]}) when op in @operators,
    do: {:ok, %{"value" => value, "operator" => op, "compare" => to_string(compare)}}

  defp condition(_other), do: :error

  defp otherwise([]), do: {:ok, ""}
  defp otherwise([{:lit, text}]) when is_binary(text), do: {:ok, text}
  defp otherwise(_other), do: :error

  defp ref_names(refs) do
    if Enum.all?(refs, &match?({:ref, _}, &1)),
      do: {:ok, Enum.map(refs, fn {:ref, name} -> name end)},
      else: :error
  end

  defp slots(keys, names),
    do: keys |> Enum.zip(names ++ List.duplicate("", length(keys))) |> Map.new()
end
