defmodule KilnCMS.CMS.FieldTypes.Geolocation do
  @moduledoc """
  A **geolocation** custom field (#428): a latitude/longitude pair, optionally
  with a map `zoom` level and a human `label` for the place.

  Built on `Kiln.FieldType` rather than as a core type — it's the worked
  example of a *composite* field type (see `input_parts/1`), and proves the
  registry can carry a structured value end to end without a core edit.

  ## Stored shape

      %{"lat" => 51.5074, "lng" => -0.1278, "zoom" => 12, "label" => "London"}

  `lat`/`lng` are always floats; `zoom`/`label` are omitted when not supplied.
  JSON-native throughout, so the `custom_fields` jsonb column round-trips it and
  delivery serves it as-is.

  ## Accepted input

    * the editor's part map — `%{"lat" => "51.5074", "lng" => "-0.1278", …}`;
    * a stored map round-tripped by an API client (atom or string keys);
    * a `"lat,lng"` string, which is also what a definition's `default` must be
      (that column is a plain string).

  Latitude is bounded to ±90 and longitude to ±180, so a transposed pair
  (`-0.1278, 51.5074` for London) is usually caught rather than silently
  dropping the point in the Arctic Ocean.

  ## Delivery

  Values ride on `custom_fields`, so every existing surface carries them. The
  fired `:json_ld` artifact additionally expresses each geolocation field as a
  schema.org `Place`/`GeoCoordinates` node under the document's
  `contentLocation` — see `KilnCMS.Firing.CustomFields`.
  """
  use Kiln.FieldType

  # Web Mercator tile zoom levels; anything outside this is a typo, not a view.
  @zoom_range 0..24
  @label_max 200

  @impl Kiln.FieldType
  def label, do: "Geolocation"

  @impl Kiln.FieldType
  def cast(value, _definition) do
    with {:ok, parts} <- parts(value),
         {:ok, lat} <- coordinate(parts, "lat", 90, "latitude"),
         {:ok, lng} <- coordinate(parts, "lng", 180, "longitude"),
         {:ok, extra} <- optional(parts) do
      {:ok, Map.merge(%{"lat" => lat, "lng" => lng}, extra)}
    end
  end

  @doc ~S"""
  The named parts of a coordinate, as slug/alias pattern tokens (#804).

  The generic `[field:<name>]` path expands a map value to `""` — honest for a
  scalar, useless for a composite — so a pattern that wants the latitude says
  `[field:location.lat]`, and this is what makes that resolvable.

  Each match is anchored to *this definition's own name*, so two geolocation
  fields on one content type (`location` and `venue`) never contend for a
  token. `label` is offered too, since a place name is usually what belongs in
  a URL; `zoom` deliberately is not — a map viewport is not an address.
  """
  @impl Kiln.FieldType
  def tokens(definition) do
    name = Regex.escape(definition.name)

    for part <- ~w(lat lng label) do
      %{
        match: ~r/\Afield:#{name}\.#{part}\z/,
        resolve: fn _token, context -> part_value(definition.name, part, context) end
      }
    end
  end

  defp part_value(field, part, context) do
    case Map.get(context[:custom_fields] || %{}, field) do
      %{} = value -> value |> Map.get(part) |> to_token()
      _absent -> ""
    end
  end

  defp to_token(nil), do: ""
  defp to_token(value) when is_binary(value), do: value
  defp to_token(value) when is_number(value), do: to_string(value)
  defp to_token(_other), do: ""

  # The four inputs the editor renders, in order. `step: "any"` matters: a
  # number input defaults to integer steps, which browsers reject decimals
  # against — i.e. every real coordinate.
  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{
        key: "lat",
        label: "Latitude",
        type: "number",
        attrs: %{step: "any", min: -90, max: 90, placeholder: "51.5074"}
      },
      %{
        key: "lng",
        label: "Longitude",
        type: "number",
        attrs: %{step: "any", min: -180, max: 180, placeholder: "-0.1278"}
      },
      # `required?: false` — a required geolocation needs a coordinate; the
      # place name and zoom stay optional either way.
      %{
        key: "label",
        label: "Place name",
        type: "text",
        required?: false,
        attrs: %{placeholder: "London"}
      },
      %{
        key: "zoom",
        label: "Map zoom",
        type: "number",
        required?: false,
        attrs: %{step: 1, min: 0, max: 24, placeholder: "12"}
      }
    ]
  end

  # --- casting ---------------------------------------------------------------

  # Normalize every accepted input shape to a string-keyed map of raw parts.
  # `not is_struct` matters: a bare `is_map` guard admits e.g. a `%Date{}` from
  # an Elixir/MCP/seed caller, and `Map.new/2` over it raises Protocol.
  # UndefinedError — a 500 where `cast/2` owes `{:error, message}`.
  defp parts(value) when is_map(value) and not is_struct(value),
    do: {:ok, Map.new(value, fn {k, v} -> {to_string(k), v} end)}

  defp parts(value) when is_binary(value) do
    case value |> String.split(",") |> Enum.map(&String.trim/1) do
      [lat, lng] -> {:ok, %{"lat" => lat, "lng" => lng}}
      _ -> {:error, format_message()}
    end
  end

  defp parts(_value), do: {:error, format_message()}

  defp coordinate(parts, key, limit, name) do
    case number(Map.get(parts, key)) do
      {:ok, number} when number >= -limit and number <= limit ->
        {:ok, number}

      {:ok, _out_of_range} ->
        {:error, "#{name} must be between -#{limit} and #{limit}"}

      :out_of_range ->
        {:error, "#{name} must be between -#{limit} and #{limit}"}

      :error ->
        {:error, format_message()}
    end
  end

  # `zoom` and `label` are genuinely optional: blank means "not set", which
  # drops the key rather than storing a null.
  defp optional(parts) do
    with {:ok, extra} <- zoom(parts) do
      put_label(extra, Map.get(parts, "label"))
    end
  end

  defp put_label(extra, blank) when blank in [nil, ""], do: {:ok, extra}

  # Only strings and numbers become labels. `to_string/1` on a client-supplied
  # map raises Protocol.UndefinedError, and on a list it silently produces
  # nonsense via List.Chars — neither is a place name.
  defp put_label(extra, raw) when is_binary(raw) or is_number(raw) do
    case raw |> to_string() |> String.trim() do
      "" ->
        {:ok, extra}

      # `String.length/1`, not `byte_size/1`: the cap reads as a character count,
      # and bytes would reject a Japanese place name at a third of the limit.
      trimmed when byte_size(trimmed) > @label_max * 4 ->
        {:error, "place name is too long"}

      trimmed ->
        if String.length(trimmed) > @label_max,
          do: {:error, "place name is too long"},
          else: {:ok, Map.put(extra, "label", trimmed)}
    end
  end

  defp put_label(_extra, _raw), do: {:error, "place name must be text"}

  defp zoom(parts), do: parts |> Map.get("zoom") |> parse_zoom()

  defp parse_zoom(blank) when blank in [nil, ""], do: {:ok, %{}}

  defp parse_zoom(raw) do
    case number(raw) do
      {:ok, number} -> zoom_level(round(number))
      _not_a_zoom -> {:error, zoom_message()}
    end
  end

  defp zoom_level(zoom) when zoom in @zoom_range, do: {:ok, %{"zoom" => zoom}}
  defp zoom_level(_zoom), do: {:error, zoom_message()}

  defp number(value) when is_float(value), do: {:ok, value}

  # `value / 1` on an integer beyond double range raises ArithmeticError, so a
  # 400-digit JSON integer for `lat` would 500 a public write instead of failing
  # the range check. Integer/float comparison on the BEAM is exact and does not
  # convert, so bounding first is safe — and anything outside this window is out
  # of range for every caller here (±180 for coordinates, 0..24 for zoom).
  defp number(value) when is_integer(value) do
    if value >= -1_000 and value <= 1_000, do: {:ok, value / 1}, else: :out_of_range
  end

  defp number(value) when is_binary(value) do
    # `Computed.safe_float/1`, not `Float.parse/1`: the latter *raises* on a
    # literal that overflows a double under Elixir 1.19 (this project's pinned
    # toolchain) and merely returns `:error` under 1.20 — and this runs on a
    # public write surface, where a raise is a 500 rather than a validation
    # message.
    case value |> String.trim() |> KilnCMS.CMS.Computed.safe_float() do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp number(_value), do: :error

  defp format_message,
    do: "must be a latitude and longitude (e.g. 51.5074, -0.1278)"

  defp zoom_message, do: "map zoom must be a whole number from 0 to 24"
end
