defmodule KilnCMS.CMS.FieldSchema do
  @moduledoc """
  The optional JSON Schema a `:json` custom field carries in its
  `validation["json_schema"]` (#2434), and the bounded check of a value
  against it.

  ## Dialect

  **JSON Schema draft 2020-12**, through the [`jsv`](https://hex.pm/packages/jsv)
  library (the only draft it supports by default). `$schema`, when given, must
  be that draft's URI. `format` is an annotation only: formats are not
  asserted.

  ## Bounds

  A schema is admin input that runs on every write, so it is bounded:

    * at most 16 KB once encoded, 16 levels deep and 1,000 values;
    * **no remote references, ever.** `$ref` must be a same-document pointer
      (`#/$defs/x`); `$id`, `$dynamicRef` and `$recursiveRef` are refused, and the
      builder's resolver chain (embedded meta-schemas and same-document
      pointers) has no network resolver, so an address cannot be fetched
      even by a keyword this module does not name;
    * a check runs in its own process with a 1-second deadline, so a schema
      that is expensive to evaluate (a pathological `pattern`, say) fails the
      write with a message instead of holding the request. The value it
      checks is already capped (64 KB, 32 levels, 5,000 values) by
      `KilnCMS.CMS.FieldTypes.Json`. Only the check of the value is timed:
      the schema is built first, in the caller. That is the same build
      `check_schema/1` runs when the definition is saved, bounded by the
      schema limits above, so a slow build (a cold or busy node) never
      refuses a valid value (#3063).

  Failures are readable sentences naming the JSON Pointer of the offending
  value (`/dosage: value 1 is lower than minimum 3`), at most five of them.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_bytes 16 * 1024
  @max_depth 16
  @max_nodes 1_000
  @deadline_ms 1_000
  @max_messages 5
  @draft "https://json-schema.org/draft/2020-12/schema"
  @refused_keys ~w($id $dynamicRef $recursiveRef $dynamicAnchor)

  # Kinds that only say "a child failed"; the child's own message is the news.
  @aggregate_kinds [
    :properties,
    :items,
    :prefixItems,
    :additionalProperties,
    :patternProperties,
    :allOf,
    :dependentSchemas,
    :unevaluatedProperties,
    :unevaluatedItems,
    :contains,
    :propertyNames
  ]

  @doc "The largest encoded schema, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The draft this module validates against."
  @spec draft() :: String.t()
  def draft, do: @draft

  @doc """
  Whether `schema` (a decoded JSON object) can be stored: bounded, free of
  remote references, and a schema the builder accepts. `{:error, message}`
  is readable.
  """
  @spec check_schema(term()) :: :ok | {:error, String.t()}
  def check_schema(%{} = schema) when not is_struct(schema) do
    with :ok <- size(schema),
         {:ok, _left} <- walk(schema, 1, @max_nodes),
         :ok <- draft_ok(schema),
         {:ok, _root} <- build(schema) do
      :ok
    end
  end

  def check_schema(_other), do: {:error, "expected a JSON object"}

  @doc """
  `:ok`, or `{:error, [message]}` for `value` against `schema`. A schema that
  no longer builds, or a check past its deadline, is one message rather than
  a raise.

  The schema is built before the deadline starts; the deadline bounds only
  the check of `value`. `opts` exist for tests: `:deadline_ms` (default
  #{@deadline_ms}) and `:build`, a function standing in for the builder.
  """
  @spec validate(term(), map(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(value, %{} = schema, opts \\ []) do
    build = Keyword.get(opts, :build, &build/1)

    case build.(schema) do
      {:ok, root} -> check(value, root, Keyword.get(opts, :deadline_ms, @deadline_ms))
      {:error, message} -> {:error, [message]}
    end
  end

  defp check(value, root, deadline_ms) do
    locale = Gettext.get_locale(KilnCMSWeb.Gettext)

    run = fn ->
      Gettext.put_locale(KilnCMSWeb.Gettext, locale)
      run_check(value, root)
    end

    # A full supervisor exits the caller; that is a refusal, not a crash.
    task =
      try do
        Task.Supervisor.async_nolink(KilnCMS.TaskSupervisor, run)
      catch
        :exit, _reason -> nil
      end

    case task && (Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill)) do
      {:ok, :ok} -> :ok
      {:ok, {:error, messages}} -> {:error, messages}
      nil -> {:error, [gettext("took too long to check against the schema")]}
      _other -> {:error, [gettext("could not be checked against the schema")]}
    end
  end

  defp run_check(value, root) do
    case JSV.validate(value, root) do
      {:ok, _cast} -> :ok
      {:error, error} -> {:error, messages(error)}
    end
  end

  # --- build -----------------------------------------------------------------

  defp build(schema) do
    case JSV.build(schema, default_meta: @draft) do
      {:ok, root} -> {:ok, root}
      {:error, error} -> {:error, build_message(error)}
    end
  rescue
    # The builder is total for maps, but a hostile schema must not raise.
    _error -> {:error, gettext("is not a valid JSON Schema")}
  end

  defp ref_message, do: gettext(~s[may only reference itself (a "$ref" starting with "#")])

  defp build_message(%JSV.BuildError{reason: {:resolver_error, _}}),
    do: ref_message()

  defp build_message(_error), do: gettext("is not a valid JSON Schema")

  # --- bounds ----------------------------------------------------------------

  defp size(schema) do
    case Jason.encode(schema) do
      {:ok, text} when byte_size(text) <= @max_bytes ->
        :ok

      {:ok, _text} ->
        {:error, gettext("is too large (at most %{kb} KB)", kb: div(@max_bytes, 1024))}

      {:error, _} ->
        {:error, gettext("must be a JSON object")}
    end
  end

  defp draft_ok(%{"$schema" => @draft}), do: :ok

  defp draft_ok(%{"$schema" => _other}),
    do: {:error, gettext(~s[must use draft 2020-12 ("$schema": "%{draft}")], draft: @draft)}

  defp draft_ok(_schema), do: :ok

  # Walks the schema once: depth, node count and the references that must not
  # exist. Stops at the first problem. `{:ok, budget_left}` threads the count.
  defp walk(_term, _depth, budget) when budget <= 0,
    do: {:error, gettext("has more than %{max} values", max: @max_nodes)}

  defp walk(_term, depth, _budget) when depth > @max_depth,
    do: {:error, gettext("is nested more than %{max} levels deep", max: @max_depth)}

  defp walk(%{} = map, depth, budget) do
    Enum.reduce_while(map, {:ok, budget - 1}, fn {key, value}, {:ok, budget} ->
      with :ok <- key_ok(key, value),
           {:ok, left} <- descend(key, value, depth + 1, budget) do
        {:cont, {:ok, left}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp walk(list, depth, budget) when is_list(list) do
    Enum.reduce_while(list, {:ok, budget - 1}, fn value, {:ok, budget} ->
      case walk(value, depth + 1, budget) do
        {:ok, left} -> {:cont, {:ok, left}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp walk(_scalar, _depth, budget), do: {:ok, budget - 1}

  # Instance data (`enum`, `const`, `default`, `examples`) is not schema: a key
  # named `$ref` in it is just data. Its size still counts.
  defp descend(key, value, depth, budget) when key in ["enum", "const", "default", "examples"],
    do: data(value, depth, budget)

  # A name -> schema map: its keys are names (a property may be called
  # `$ref`), only its values are schemas.
  defp descend(key, %{} = value, depth, budget)
       when key in ["properties", "$defs", "definitions", "patternProperties", "dependentSchemas"] do
    Enum.reduce_while(value, {:ok, budget - 1}, fn {_name, schema}, {:ok, budget} ->
      step(walk(schema, depth + 1, budget))
    end)
  end

  defp descend(_key, value, depth, budget), do: walk(value, depth, budget)

  defp data(_value, depth, _budget) when depth > @max_depth,
    do: {:error, gettext("is nested more than %{max} levels deep", max: @max_depth)}

  defp data(_value, _depth, budget) when budget <= 0,
    do: {:error, gettext("has more than %{max} values", max: @max_nodes)}

  defp data(%{} = map, depth, budget) do
    Enum.reduce_while(map, {:ok, budget - 1}, fn {_key, value}, {:ok, budget} ->
      step(data(value, depth + 1, budget))
    end)
  end

  defp data(list, depth, budget) when is_list(list) do
    Enum.reduce_while(list, {:ok, budget - 1}, fn value, {:ok, budget} ->
      step(data(value, depth + 1, budget))
    end)
  end

  defp data(_scalar, _depth, budget), do: {:ok, budget - 1}

  defp step({:ok, left}), do: {:cont, {:ok, left}}
  defp step({:error, _} = error), do: {:halt, error}

  defp key_ok(key, _value) when key in @refused_keys,
    do: {:error, gettext("can't use \"%{key}\"", key: key)}

  defp key_ok("$ref", "#" <> _local), do: :ok

  defp key_ok("$ref", value) when is_binary(value),
    do: {:error, ref_message()}

  defp key_ok(_key, _value), do: :ok

  # --- messages --------------------------------------------------------------

  defp messages(error) do
    error
    |> JSV.normalize_error()
    |> Map.get(:details, [])
    |> Enum.flat_map(fn detail ->
      for %{kind: kind, message: message} <- Map.get(detail, :errors, []),
          kind not in @aggregate_kinds do
        sentence(Map.get(detail, :instanceLocation, "#"), message)
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@max_messages)
    |> case do
      [] -> [gettext("doesn't match the schema")]
      messages -> messages
    end
  end

  defp sentence("#", message), do: message

  defp sentence("#" <> pointer, message), do: "#{pointer}: #{message}"
end
