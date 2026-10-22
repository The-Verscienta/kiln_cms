defmodule KilnCMSWeb.ArtifactFields do
  @moduledoc """
  `?fields=` on the fired `json` artifact (`GET /api/content/:type/:slug`): a
  sparse fieldset for clients on constrained networks that want a list row or
  a widget, not the whole document, and do not run GraphQL.

  `?fields=title,slug,custom_fields.price` keeps those top-level keys and only
  the named custom fields. The rules:

    * names are comma-separated top-level keys of the artifact (`title`,
      `slug`, `locale`, `blocks`, `custom_fields`, …), plus
      `custom_fields.<name>` for one custom field;
    * `id` and `type` are always kept — they address the document — and so is
      `expanded`, which only `?expand=` asks for;
    * an unknown name is ignored, not refused: a client built against a type
      that later gains or loses a field keeps working;
    * `custom_fields` alongside `custom_fields.<name>` means all of them;
    * at most 50 names.

  ## Validators and cache keys

  The `ETag` of a fieldset response is a digest of the filtered body
  (`KilnCMSWeb.ArtifactController`), so it changes exactly when what the
  caller kept changes: a republish that touched only `blocks` still `304`s a
  `?fields=title` revalidation. The order and repetition of the names do not
  change the body, so `?fields=slug,title` and `?fields=title,slug,title`
  share an `ETag` and a `304` answers either.

  A shared cache keys on the full URL (`docs/api.md`, "Configuring your
  CDN"), so two fieldsets are never one entry; two spellings of one fieldset
  are two. `canonical/1` sorts and de-duplicates the names (and folds
  `custom_fields.x` into a bare `custom_fields`), and the response's
  `x-kiln-fields` header carries that spelling, for a client that wants every
  install to hit one entry.
  """

  @max_fields 50
  @always ~w(id type expanded)

  @doc """
  Reads `?fields=` from the query params: `{:ok, nil}` when absent or blank,
  `{:ok, fields}` — already canonical — for a comma-separated list, or
  `{:error, message}`.
  """
  @spec parse(map()) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  def parse(%{"fields" => value}) when is_binary(value) do
    names =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      names == [] -> {:ok, nil}
      length(names) > @max_fields -> {:error, "`fields` takes at most #{@max_fields} names."}
      true -> {:ok, canonical(names)}
    end
  end

  def parse(%{"fields" => _not_a_string}),
    do: {:error, "`fields` must be a comma-separated list of names."}

  def parse(_params), do: {:ok, nil}

  @doc """
  The canonical form of a list of names: sorted, de-duplicated, without the
  always-kept `id`/`type`/`expanded`, and with every `custom_fields.<name>`
  dropped when the whole of `custom_fields` is asked for.
  """
  @spec canonical([String.t()]) :: [String.t()]
  def canonical(names) do
    names = names |> Enum.uniq() |> Enum.reject(&(&1 in @always))
    whole_custom? = "custom_fields" in names

    names
    |> Enum.reject(&(whole_custom? and String.starts_with?(&1, "custom_fields.")))
    |> Enum.sort()
  end

  @doc "The artifact `body` cut down to `fields` (`nil` = the whole body)."
  @spec select(map(), [String.t()] | nil) :: map()
  def select(body, nil), do: body

  def select(body, fields) when is_map(body) do
    {custom, top} = Enum.split_with(fields, &String.starts_with?(&1, "custom_fields."))
    selected = Map.take(body, @always ++ top)

    case {custom, Map.get(body, "custom_fields")} do
      {[_ | _], values} when is_map(values) and not is_map_key(selected, "custom_fields") ->
        names = Enum.map(custom, &String.replace_prefix(&1, "custom_fields.", ""))
        Map.put(selected, "custom_fields", Map.take(values, names))

      _ ->
        selected
    end
  end
end
