defmodule KilnCMS.CMS.FieldTypes.Link do
  @moduledoc """
  A **link** custom field (#2278): a URL with an optional label, a target and
  `rel` values, stored as
  `%{"url" => ..., "label" => ..., "target" => ..., "rel" => ...}` (every key
  but `url` is left out when not set).

  Not to be confused with the edge-metadata "link fields" of a `:reference`
  (`FieldDefinition.link_field_types/0`), which is a different thing.

  The URL is trimmed and must pass `KilnCMS.HTMLSanitizer.safe_href/1`, the
  policy menu items and rich-text links use: an `http(s)` URL, a `mailto:`
  address, a relative path (`/about`) or a `#fragment`. Anything the policy
  would rewrite or drop (`javascript:`, `data:`, a protocol-relative `//host`,
  `tel:`, a URL with control characters) is **refused** with an error, never
  stored as a placeholder. Use a `:telephone` field for a phone number. At most
  2,048 bytes.

  Other parts:

    * `label` (optional): up to 200 characters of single-line text;
    * `target`: `"_blank"` or `"_self"`, or unset;
    * `rel`: a space-separated string (or list) of `noopener`, `noreferrer`,
      `nofollow`, `sponsored`, `ugc` and `external`; anything else is refused.
      A `"_blank"` target always adds `noopener noreferrer`.

  Not filterable (other than for presence) or sortable; served through GraphQL
  as the generic JSON value. If an admin flags one `searchable`, only the
  **label** is indexed, never the URL, target or `rel`.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.HTMLSanitizer

  @max_url 2_048
  @max_label 200
  @targets ~w(_blank _self)
  @rels ~w(noopener noreferrer nofollow sponsored ugc external)
  @keys ~w(url label target rel)

  @impl Kiln.FieldType
  def label, do: "Link"

  @impl Kiln.FieldType
  def description do
    gettext(
      "A web address with an optional label, and whether it opens in a new tab. For a source, a call to action or an external resource. Cannot be filtered or sorted."
    )
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :json

  @impl Kiln.FieldType
  def json_schema(_definition) do
    %{
      "type" => ["object", "null"],
      "required" => ["url"],
      "properties" => %{
        "url" => %{"type" => "string", "maxLength" => @max_url},
        "label" => %{"type" => "string", "maxLength" => @max_label},
        "target" => %{"enum" => @targets},
        "rel" => %{"type" => "string"}
      },
      "additionalProperties" => false
    }
  end

  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{
        key: "url",
        label: gettext("Address"),
        type: "text",
        attrs: %{placeholder: "https://example.com", autocomplete: "off"}
      },
      %{
        key: "label",
        label: gettext("Label"),
        type: "text",
        required?: false,
        attrs: %{maxlength: @max_label}
      },
      %{
        key: "target",
        label: gettext("Opens in"),
        type: "select",
        required?: false,
        options: [
          {"", gettext("Default")},
          {"_self", gettext("Same tab")},
          {"_blank", gettext("New tab")}
        ]
      },
      %{
        key: "rel",
        label: gettext("Rel"),
        type: "text",
        required?: false,
        help:
          gettext("Space-separated: noopener, noreferrer, nofollow, sponsored, ugc, external."),
        attrs: %{placeholder: "nofollow sponsored"}
      }
    ]
  end

  @impl Kiln.FieldType
  def cast(value, _definition) when is_map(value) and not is_struct(value) do
    with {:ok, parts} <- parts(value),
         {:ok, url} <- url(Map.get(parts, "url")),
         {:ok, label} <- label_text(Map.get(parts, "label")),
         {:ok, target} <- target(Map.get(parts, "target")),
         {:ok, rel} <- rel(Map.get(parts, "rel"), target) do
      {:ok,
       %{"url" => url}
       |> put("label", label)
       |> put("target", target)
       |> put("rel", rel)}
    end
  end

  def cast(_value, _definition), do: {:error, "must be a link with an address"}

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp parts(map) do
    parts = Map.new(map, fn {key, value} -> {key_name(key), value} end)

    if Map.keys(parts) -- @keys == [],
      do: {:ok, parts},
      else: {:error, "may only have url, label, target and rel"}
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(_key), do: :invalid

  defp url(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "needs an address"}

      byte_size(trimmed) > @max_url ->
        {:error, "address is too long (at most #{@max_url} bytes)"}

      not plain?(trimmed) ->
        {:error, "address must be valid single-line text"}

      HTMLSanitizer.safe_href(trimmed) == trimmed ->
        {:ok, trimmed}

      true ->
        {:error, "address must be an http(s) URL, a mailto: address, a /path or a #fragment"}
    end
  end

  defp url(nil), do: {:error, "needs an address"}
  defp url(_other), do: {:error, "address must be text"}

  defp label_text(nil), do: {:ok, nil}

  defp label_text(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      not plain?(trimmed) -> {:error, "label must be single-line text"}
      String.length(trimmed) > @max_label -> {:error, "label is at most #{@max_label} characters"}
      true -> {:ok, trimmed}
    end
  end

  defp label_text(_other), do: {:error, "label must be text"}

  defp target(value) when value in [nil, ""], do: {:ok, nil}
  defp target(value) when value in @targets, do: {:ok, value}
  defp target(_other), do: {:error, "target must be _blank or _self"}

  defp rel(raw, target) do
    with {:ok, tokens} <- rel_tokens(raw) do
      tokens = if target == "_blank", do: tokens ++ ~w(noopener noreferrer), else: tokens

      case Enum.filter(@rels, &(&1 in tokens)) do
        [] -> {:ok, nil}
        ordered -> {:ok, Enum.join(ordered, " ")}
      end
    end
  end

  defp rel_tokens(nil), do: {:ok, []}

  defp rel_tokens(text) when is_binary(text) do
    if byte_size(text) <= 200 and String.valid?(text),
      do: check_rels(String.split(String.downcase(text))),
      else: {:error, "rel must be one or more of: #{Enum.join(@rels, ", ")}"}
  end

  defp rel_tokens(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) and length(list) <= 20,
      do: rel_tokens(Enum.join(list, " ")),
      else: {:error, "rel must be one or more of: #{Enum.join(@rels, ", ")}"}
  end

  defp rel_tokens(_other), do: {:error, "rel must be text"}

  defp check_rels(tokens) do
    case Enum.reject(tokens, &(&1 in @rels)) do
      [] -> {:ok, tokens}
      _ -> {:error, "rel must be one or more of: #{Enum.join(@rels, ", ")}"}
    end
  end

  # Valid UTF-8 with no control character (a NUL, a tab or a line break inside
  # an address is how `java\tscript:` gets past a naive check).
  defp plain?(text),
    do: String.valid?(text) and not String.match?(text, ~r/[\x00-\x1F\x7F]/u)
end
