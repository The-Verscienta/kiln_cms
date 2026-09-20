defmodule KilnClient.Image do
  @moduledoc """
  URL builders for Kiln's on-the-fly image transforms —
  `GET /media/:id/t/:ops`, e.g.

      /media/8a5b…0b11/t/w_828,ar_16:9,fm_auto,v_4b87b277

  Pure string building: nothing here talks to the server. The builders take a
  media item as this client returns it (a flattened JSON:API resource with
  `"id"`, `"url"`, `"focal_x"`, `"focal_y"`, `"width"`, `"height"`); atom keys
  work too. They produce byte-for-byte the URLs Kiln's own templates and the
  JS SDK produce — a shared fixture pins all three.

  ## Options

    * `:width` / `:height` — positive integers, CSS pixels.
    * `:aspect_ratio` — `"16:9"` or `{16, 9}`, each side 1–99. Instead of
      `:height`, never with it: giving both raises, as the server refuses
      the pair.
    * `:dpr` — `1`, `2` or `3`.
    * `:fit` — `:cover` (the server's default) or `:contain`.
    * `:crop` — `:focal` (default), `:center`, `:top`, `:bottom`, `:left`,
      `:right`: where a `:cover` crop is anchored.
    * `:format` — `:auto` (negotiated from `Accept`), `:jpg`, `:png`, `:webp`,
      `:avif`.
    * `:quality` — 1–100.
    * `:sign_key` — sign the URL with this key (see "Signed URLs"). Defaults
      to the configured `:image_transform_key`; pass `sign_key: nil` to build
      an unsigned URL even when one is configured.
    * `:sizes` — the unsigned size ladder (default: Kiln's default,
      `[16, 32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920,
      2048, 3840]`).
      Set it to match the server's `image_transforms: [sizes: …]` if that
      was changed.

  Atom values may also be given as strings (`fit: "contain"`). Invalid
  values raise `ArgumentError` — a typo would otherwise surface as a 400 in
  someone's browser.

  Every URL carries a version pin (`v`) when the item has a `url`: a hash of
  the stored file and its focal point, so re-uploading or moving the focal
  point changes the URL and the long-lived cache entry for the old one is
  simply never asked for again.

  ## Unsigned URLs

  Without a key, the URL is unsigned, and Kiln serves it only while every
  value is on its allowlist (unless the operator has turned unsigned URLs off
  altogether). `:width` and `:height` are snapped **up** to the next size on
  the ladder, so any width you ask for is servable; the other allowlists
  (aspect ratios `1:1 4:3 3:4 3:2 2:3 4:5 5:4 16:9 9:16 21:9`, qualities
  `50 75 90` by default) are not rewritten — an off-list value gets a 400
  explaining what is allowed.

  ## Signed URLs

  With a key, the URL is signed (`s`, an HMAC over the item id and the
  canonical parameters) and any value within the server's hard limits works,
  exactly as given — no snapping.

      config :kiln_client, image_transform_key: System.get_env("KILN_IMAGE_TRANSFORM_KEY")

  The key is the server's `KILN_IMAGE_TRANSFORM_KEY`. It is a **server-side
  secret**: use it only where the code runs on your server (a Phoenix app
  rendering pages), never in anything shipped to a browser. Anyone holding it
  can make the server render arbitrary sizes. A Kiln that has no
  `KILN_IMAGE_TRANSFORM_KEY` set signs with a key derived from its
  `SECRET_KEY_BASE`, which no client can reproduce — set the variable
  explicitly on the server to sign from here.
  """

  import Bitwise

  @typedoc "A media item: a flattened JSON:API resource (string keys) or an atom-keyed map."
  @type media :: map()

  @default_sizes [16, 32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, 3840]

  @fits [:cover, :contain]
  @crops [:focal, :center, :top, :bottom, :left, :right]
  @formats [:auto, :jpg, :png, :webp, :avif]

  @fnv_offset 0x811C9DC5
  @fnv_prime 0x01000193

  @doc """
  The version token (`v`) for `media`: FNV-1a 32-bit over
  `"<url>|<round(focal_x * 1000)>|<round(focal_y * 1000)>"` (a missing focal
  coordinate counts as `0.5`), as 8 lowercase hex digits. `nil` when the item
  has no `url` — a version of nothing would never match the server's.
  """
  @spec version(media()) :: String.t() | nil
  def version(media) do
    case field(media, :url) do
      nil ->
        nil

      url ->
        "#{url}|#{milli(field(media, :focal_x))}|#{milli(field(media, :focal_y))}"
        |> fnv1a32()
        |> Integer.to_string(16)
        |> String.downcase()
        |> String.pad_leading(8, "0")
    end
  end

  @doc """
  The transform path for `media`, `"/media/<id>/t/<ops>"` — for when the page
  and Kiln share an origin, or you prefix the host yourself. Takes the options
  in the module doc.

      KilnClient.Image.path(item, width: 800, aspect_ratio: "16:9", format: :auto)
      #=> "/media/8a5b…/t/w_828,ar_16:9,fm_auto,v_4b87b277"
  """
  @spec path(media(), keyword()) :: String.t()
  def path(media, opts \\ []) do
    key = sign_key(opts)

    width =
      opts
      |> Keyword.get(:width)
      |> maybe(&positive_int!(:width, &1))
      |> maybe(&snap_unsigned(&1, key, opts))

    build(media, opts, width, key)
  end

  @doc """
  The absolute transform URL for `media`: `path/2` prefixed with
  `KilnClient.public_url/0` (the configured `:public_url`, else `:base_url`).
  """
  @spec url(media(), keyword()) :: String.t()
  def url(media, opts \\ []), do: absolute(path(media, opts))

  @doc """
  A `srcset` attribute value of absolute transform URLs for `media`, or `nil`
  when the item has no positive integer `width` and `height` (nothing Kiln
  could transform, or dimensions not yet known).

  Takes the options in the module doc, plus `:widths` — the candidate widths
  (default: the ladder from 256 up). Unsigned, each width is snapped up to
  the ladder. `:height` is ignored: a fixed height would give every
  candidate a different shape. Pass `:aspect_ratio` for a cropped set.

  Each candidate is described by the width it can really render at,
  `min(w, widest)` — `widest` being the item's width, or for `a:b` the width
  of the largest `a:b` window, `min(width, round(height * a / b))`. Kiln
  never upscales, so candidates past `widest` would all render the same
  image; only the first of them is kept.

      KilnClient.Image.srcset(item, widths: [640, 1080, 1920], format: :auto)
      #=> "https://cms…/media/…/t/w_640,fm_auto,v_… 640w, …"
  """
  @spec srcset(media(), keyword()) :: String.t() | nil
  def srcset(media, opts \\ []) do
    case srcset_candidates(media, opts) do
      nil -> nil
      candidates -> Enum.map_join(candidates, ", ", fn {path, w} -> "#{absolute(path)} #{w}w" end)
    end
  end

  defp srcset_candidates(media, opts) do
    sw = field(media, :width)
    sh = field(media, :height)

    if is_integer(sw) and sw > 0 and is_integer(sh) and sh > 0 do
      key = sign_key(opts)
      widest = widest(sw, sh, opts |> Keyword.get(:aspect_ratio) |> ratio())
      opts = Keyword.delete(opts, :height)

      (Keyword.get(opts, :widths) || Enum.filter(sizes(opts), &(&1 >= 256)))
      |> Enum.map(&positive_int!(:widths, &1))
      |> Enum.map(&snap_unsigned(&1, key, opts))
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&{&1, min(&1, widest)})
      |> Enum.uniq_by(fn {_w, described} -> described end)
      |> Enum.map(fn {w, described} -> {build(media, opts, w, key), described} end)
    end
  end

  defp widest(sw, _sh, nil), do: sw
  defp widest(sw, sh, {a, b}), do: min(sw, max(1, round(sh * a / b)))

  # --- internal: building ---

  # `width` arrives already snapped (or not); everything else is taken from
  # `opts`. Canonical order: w, h, ar, dpr, fit, crop, fm, q, v — then s.
  defp build(media, opts, width, key) do
    if Keyword.get(opts, :height) && Keyword.get(opts, :aspect_ratio) do
      # The server refuses `h` with `ar` (which would win is ambiguous).
      raise ArgumentError, "pass :height or :aspect_ratio, not both"
    end

    id =
      case field(media, :id) do
        nil -> raise ArgumentError, "media has no id: #{inspect(media)}"
        id -> to_string(id)
      end

    ops =
      [
        w: width && positive_int!(:width, width),
        h:
          opts
          |> Keyword.get(:height)
          |> maybe(&positive_int!(:height, &1))
          |> maybe(&snap_unsigned(&1, key, opts)),
        ar: opts |> Keyword.get(:aspect_ratio) |> ratio() |> maybe(fn {a, b} -> "#{a}:#{b}" end),
        dpr: opts |> Keyword.get(:dpr) |> maybe(&in_range!(:dpr, &1, 1..3)),
        fit: opts |> Keyword.get(:fit) |> maybe(&one_of!(:fit, &1, @fits)),
        crop: opts |> Keyword.get(:crop) |> maybe(&one_of!(:crop, &1, @crops)),
        fm: opts |> Keyword.get(:format) |> maybe(&one_of!(:format, &1, @formats)),
        q: opts |> Keyword.get(:quality) |> maybe(&in_range!(:quality, &1, 1..100)),
        v: version(media)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(",", fn {k, value} -> "#{k}_#{value}" end)

    ops = if key, do: "#{ops},s_#{sign(id, ops, key)}", else: ops
    "/media/#{id}/t/#{ops}"
  end

  defp sign(id, ops, key) do
    :hmac
    |> :crypto.mac(:sha256, key, "#{id}/#{ops}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp sign_key(opts) do
    case Keyword.fetch(opts, :sign_key) do
      {:ok, key} -> present_key(key)
      :error -> present_key(Application.get_env(:kiln_client, :image_transform_key))
    end
  end

  defp present_key(key) when is_binary(key) and key != "", do: key
  defp present_key(_unset), do: nil

  defp sizes(opts) do
    case Keyword.get(opts, :sizes, @default_sizes) do
      [_ | _] = sizes -> sizes |> Enum.map(&positive_int!(:sizes, &1)) |> Enum.sort()
      other -> raise ArgumentError, "sizes must be a non-empty list, got: #{inspect(other)}"
    end
  end

  # Unsigned sizes go up to the next rung (the top rung past the top); signed
  # ones are taken exactly as given.
  defp snap_unsigned(value, key, _opts) when is_binary(key), do: value

  defp snap_unsigned(value, nil, opts) do
    sizes = sizes(opts)
    Enum.find(sizes, List.last(sizes), &(&1 >= value))
  end

  defp absolute(path), do: String.trim_trailing(KilnClient.public_url(), "/") <> path

  # --- internal: validation ---

  defp maybe(nil, _fun), do: nil
  defp maybe(value, fun), do: fun.(value)

  defp positive_int!(_name, value) when is_integer(value) and value > 0, do: value

  defp positive_int!(name, value),
    do: raise(ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}")

  defp in_range!(name, value, first..last//_) do
    if is_integer(value) and value in first..last//1 do
      value
    else
      raise ArgumentError, "#{name} must be an integer #{first}–#{last}, got: #{inspect(value)}"
    end
  end

  defp one_of!(name, value, allowed) do
    if Enum.any?(allowed, &(&1 == value or Atom.to_string(&1) == value)) do
      to_string(value)
    else
      raise ArgumentError,
            "#{name} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
    end
  end

  defp ratio(nil), do: nil

  defp ratio({a, b}) when a in 1..99//1 and b in 1..99//1, do: {a, b}

  defp ratio(string) when is_binary(string) do
    if string =~ ~r/\A[1-9][0-9]?:[1-9][0-9]?\z/ do
      [a, b] = String.split(string, ":")
      {String.to_integer(a), String.to_integer(b)}
    else
      bad_ratio(string)
    end
  end

  defp ratio(other), do: bad_ratio(other)

  defp bad_ratio(value) do
    raise ArgumentError,
          "aspect_ratio must be \"a:b\" or {a, b} with each side 1–99, got: #{inspect(value)}"
  end

  # --- internal: version hash ---

  defp milli(value) when is_number(value), do: round(value * 1000)
  defp milli(_missing), do: 500

  defp fnv1a32(string) do
    for <<byte <- string>>, reduce: @fnv_offset do
      hash -> bxor(hash, byte) * @fnv_prime &&& 0xFFFFFFFF
    end
  end

  defp field(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end
end
