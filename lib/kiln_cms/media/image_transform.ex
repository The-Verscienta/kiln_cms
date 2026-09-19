defmodule KilnCMS.Media.ImageTransform do
  @moduledoc """
  On-the-fly image transforms: the URL grammar, who may ask for what,
  and the arithmetic that turns a request into one output image.

      /media/<id>/t/w_800,ar_16:9,fm_auto,v_3f2a9c01

  This module is pure — no storage, no database, no libvips. It parses and
  authorizes the `<ops>` segment, plans the crop and output size against the
  item's recorded dimensions, and builds URLs. `KilnCMS.Media.Derivatives`
  renders and caches; `KilnCMSWeb.MediaTransformController` serves. The grammar
  is also implemented by both SDKs (`clients/js`, `clients/elixir/kiln_client`),
  and `clients/js/test/fixtures/image_transform_vectors.json` pins all three to
  the same URLs.

  ## Parameters

  | key    | values                                    | meaning |
  |--------|-------------------------------------------|---------|
  | `w`    | 1–`max_dimension` (4000)                  | width, CSS px |
  | `h`    | 1–`max_dimension`                         | height, CSS px |
  | `ar`   | `<a>:<b>`, each 1–99                      | aspect ratio (width:height), instead of `h` |
  | `dpr`  | `1`, `2`, `3`                             | device-pixel ratio; multiplies `w`/`h` |
  | `fit`  | `cover` (default), `contain`              | fill the box and crop, or fit inside it |
  | `crop` | `focal` (default), `center`, `top`, `bottom`, `left`, `right` | where a `cover` crop is anchored |
  | `fm`   | `auto`, `jpg`, `png`, `webp`, `avif`      | output format; default is the source's |
  | `q`    | 1–100                                     | quality, lossy formats only |
  | `v`    | 8 hex digits                              | version pin — see "Caching" |
  | `s`    | 22 url-safe base64 characters             | HMAC signature — see "Abuse" |

  Parameters are `key_value`, joined by commas, each at most once. The
  **canonical** form orders them `w, h, ar, dpr, fit, crop, fm, q, v` — the
  order the builders emit and the string a signature covers. The server
  accepts any order.

  Output is never upscaled: a box larger than the source (or its crop window)
  yields the largest image the source can supply at the requested aspect
  ratio. `fm_auto` picks from the request's `Accept` header (AVIF when the
  operator has opted in, then WebP, then the source format) and is served
  with `Vary: Accept`. Animated GIFs are flattened to their first frame and
  default to PNG.

  ## Abuse

  Every distinct parameter set is a decode, a resize and an encode, so an open
  endpoint is a CPU and storage amplifier. Two postures, both on by default:

    * **Unsigned URLs are held to an allowlist** — `w`/`h` from `sizes`, `ar`
      from `aspect_ratios`, `q` from `unsigned_qualities`. Off-list values are
      a 400. The SDK builders snap up to the allowlist, so a browser-side
      caller never has to know it exists.
    * **Signed URLs may use any in-range value.** `s` is an HMAC-SHA256 over
      `"<id>/<canonical ops>"`, truncated to 128 bits. The key is
      `KILN_IMAGE_TRANSFORM_KEY` when set (share it with a server-side
      frontend to let it sign), else derived from `SECRET_KEY_BASE` — which
      Kiln's own templates can use but no one else can.

  `KILN_IMAGE_TRANSFORM_UNSIGNED=false` turns the allowlist path off.
  Independent of both: `max_dimension` bounds every output side, a source
  over `max_source_pixels` is refused before it is decoded, and
  `KilnCMS.Media.Derivatives` holds a per-item derivative budget, a render
  concurrency gate and (in the controller) a per-IP render rate limit.

  ## Caching

  `v` is `version/1` — a hash of the item's `url` and focal point, the two
  things that change a transform's pixels (a rotate or replace mints a new
  storage key and therefore a new `url`; a focal move changes every focal
  crop). A request whose `v` matches is served `immutable` for a year; one
  with no `v` or a stale one gets the current image with a five-minute
  lifetime. The derivative cache underneath is keyed on the *output*, not the
  URL, so it is never stale either way.

  The hash is FNV-1a (32-bit) over `"<url>|<focal_x*1000>|<focal_y*1000>"`,
  rounded to integers and with a missing focal point read as the centre —
  chosen because every client can compute it synchronously from the public
  `url`/`focal_x`/`focal_y` attributes it already has.
  """

  alias KilnCMS.ImageProcessor

  @keys ~w(w h ar dpr fit crop fm q v s)
  @canonical_order [:w, :h, :ar, :dpr, :fit, :crop, :fm, :q, :v]

  @fits ~w(cover contain)
  @crops ~w(focal center top bottom left right)
  @formats ~w(auto jpg png webp avif)

  # The longest `<ops>` segment worth parsing. The longest legal one is ~70
  # bytes; the cap only exists so a hostile path is rejected before it is split.
  @max_ops_bytes 200

  # Next.js's default `deviceSizes ++ imageSizes`: the ladder most frontend
  # developers already know, dense where phones are and sparse above 2K.
  @default_sizes [16, 32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, 3840]
  @default_aspect_ratios ~w(1:1 4:3 3:4 3:2 2:3 4:5 5:4 16:9 9:16 21:9)
  @default_unsigned_qualities [50, 75, 90]
  @default_max_dimension 4000

  # Bumped when rendering changes in a way that should not be served from a
  # derivative written by the old code (a new resampling kernel, say).
  @engine "kiln-transform-1"

  @format_info %{
    jpg: {".jpg", "image/jpeg"},
    png: {".png", "image/png"},
    webp: {".webp", "image/webp"},
    avif: {".avif", "image/avif"}
  }

  # The raster types an item can be transformed from — the upload allowlist
  # (`ImageProcessor.validate_upload/1`), and the default output for each.
  # A GIF's transform is a still of its first frame, which PNG holds losslessly.
  @source_formats %{
    "image/jpeg" => :jpg,
    "image/png" => :png,
    "image/webp" => :webp,
    "image/gif" => :png
  }

  defmodule Params do
    @moduledoc "A parsed `<ops>` segment. `ar` is `{a, b}`; enums are atoms."
    defstruct [:w, :h, :ar, :dpr, :fit, :crop, :fm, :q, :v, :s]

    @type t :: %__MODULE__{
            w: pos_integer() | nil,
            h: pos_integer() | nil,
            ar: {pos_integer(), pos_integer()} | nil,
            dpr: 1..3 | nil,
            fit: :cover | :contain | nil,
            crop: :focal | :center | :top | :bottom | :left | :right | nil,
            fm: :auto | :jpg | :png | :webp | :avif | nil,
            q: 1..100 | nil,
            v: String.t() | nil,
            s: String.t() | nil
          }
  end

  defmodule Plan do
    @moduledoc """
    One output image: the crop window in source pixels (`nil` for the whole
    frame), the output size, format and quality, and the derivative cache key
    those determine.
    """
    defstruct [
      :crop,
      :width,
      :height,
      :format,
      :quality,
      :content_type,
      :ext,
      :cache_key,
      :focal,
      vary_accept?: false
    ]

    @type t :: %__MODULE__{
            crop: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()} | nil,
            width: pos_integer(),
            height: pos_integer(),
            format: :jpg | :png | :webp | :avif,
            quality: 1..100 | nil,
            content_type: String.t(),
            ext: String.t(),
            cache_key: String.t(),
            focal: String.t() | nil,
            vary_accept?: boolean()
          }
  end

  @type error :: {:error, :bad_request | :forbidden | :unprocessable, String.t()}

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  @doc false
  def config, do: Application.get_env(:kiln_cms, :image_transforms, [])

  @doc "Whether unsigned (allowlisted) URLs are accepted."
  @spec allow_unsigned?() :: boolean()
  def allow_unsigned?, do: Keyword.get(config(), :allow_unsigned, true) != false

  @doc "The widths and heights an unsigned URL may ask for."
  @spec sizes() :: [pos_integer()]
  def sizes, do: config() |> Keyword.get(:sizes, @default_sizes) |> Enum.sort()

  @doc "The aspect ratios an unsigned URL may ask for, as `\"a:b\"` strings."
  @spec aspect_ratios() :: [String.t()]
  def aspect_ratios, do: Keyword.get(config(), :aspect_ratios, @default_aspect_ratios)

  @doc "The qualities an unsigned URL may ask for."
  @spec unsigned_qualities() :: [pos_integer()]
  def unsigned_qualities,
    do: Keyword.get(config(), :unsigned_qualities, @default_unsigned_qualities)

  @doc "The largest output side, after `dpr`."
  @spec max_dimension() :: pos_integer()
  def max_dimension, do: Keyword.get(config(), :max_dimension, @default_max_dimension)

  @doc """
  The largest source, in pixels, a transform will decode. Defaults to the
  upload cap (`config :kiln_cms, :media, max_pixels:`), so lowering that
  bounds transforms of existing originals too.
  """
  @spec max_source_pixels() :: pos_integer()
  def max_source_pixels do
    Keyword.get_lazy(config(), :max_source_pixels, &ImageProcessor.max_pixels/0)
  end

  defp auto_avif?, do: Keyword.get(config(), :auto_avif, false) == true

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses an `<ops>` segment. Rejects unknown or repeated keys, malformed
  values and `h` together with `ar`; range checks against `max_dimension/0`
  happen here too, so nothing downstream sees an out-of-range number.
  """
  @spec parse(String.t()) :: {:ok, Params.t()} | error()
  def parse(ops) when is_binary(ops) and byte_size(ops) in 1..@max_ops_bytes do
    ops
    |> String.split(",")
    |> Enum.reduce_while({:ok, %Params{}, MapSet.new()}, fn pair, {:ok, params, seen} ->
      case parse_pair(pair, seen) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(params, key, value), MapSet.put(seen, key)}}
        {:error, message} -> {:halt, {:error, :bad_request, message}}
      end
    end)
    |> case do
      {:ok, %Params{h: h, ar: ar}, _seen} when not is_nil(h) and not is_nil(ar) ->
        {:error, :bad_request, "Use h or ar, not both."}

      {:ok, params, _seen} ->
        {:ok, params}

      error ->
        error
    end
  end

  def parse(_ops), do: {:error, :bad_request, "Malformed transform."}

  defp parse_pair(pair, seen) do
    with [key, value] <- String.split(pair, "_", parts: 2),
         true <- key in @keys || {:error, "Unknown parameter #{inspect(key)}."},
         key = String.to_existing_atom(key),
         false <- MapSet.member?(seen, key) && {:error, "Parameter #{key} given twice."},
         {:ok, parsed} <- parse_value(key, value) do
      {:ok, key, parsed}
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "Malformed parameter #{inspect(String.slice(pair, 0, 24))}."}
    end
  end

  defp parse_value(key, value) when key in [:w, :h] do
    case positive_int(value, 5) do
      {:ok, n} ->
        if n <= max_dimension(),
          do: {:ok, n},
          else: {:error, "#{key} exceeds the maximum of #{max_dimension()}."}

      _ ->
        {:error, "#{key} must be a positive integer."}
    end
  end

  defp parse_value(:ar, value) do
    with [a, b] <- String.split(value, ":"),
         {:ok, a} when a <= 99 <- positive_int(a, 2),
         {:ok, b} when b <= 99 <- positive_int(b, 2) do
      {:ok, {a, b}}
    else
      _ -> {:error, "ar must be <width>:<height>, each 1-99."}
    end
  end

  defp parse_value(:dpr, value) when value in ~w(1 2 3), do: {:ok, String.to_integer(value)}
  defp parse_value(:dpr, _value), do: {:error, "dpr must be 1, 2 or 3."}

  defp parse_value(:fit, value) when value in @fits, do: {:ok, String.to_existing_atom(value)}
  defp parse_value(:fit, _value), do: {:error, "fit must be cover or contain."}

  defp parse_value(:crop, value) when value in @crops, do: {:ok, String.to_existing_atom(value)}

  defp parse_value(:crop, _value),
    do: {:error, "crop must be one of #{Enum.join(@crops, ", ")}."}

  defp parse_value(:fm, value) when value in @formats, do: {:ok, String.to_existing_atom(value)}
  defp parse_value(:fm, _value), do: {:error, "fm must be one of #{Enum.join(@formats, ", ")}."}

  defp parse_value(:q, value) do
    case positive_int(value, 3) do
      {:ok, q} when q <= 100 -> {:ok, q}
      _ -> {:error, "q must be 1-100."}
    end
  end

  defp parse_value(:v, value) do
    if value =~ ~r/\A[0-9a-f]{8}\z/,
      do: {:ok, value},
      else: {:error, "v must be 8 lowercase hex digits."}
  end

  defp parse_value(:s, value) do
    if value =~ ~r/\A[A-Za-z0-9_-]{22}\z/,
      do: {:ok, value},
      else: {:error, "Malformed signature."}
  end

  # Digits only, no leading zero: one spelling per number, so a signature over
  # the canonical form can't be dodged by `w_0800`.
  defp positive_int(value, max_digits) do
    if value =~ ~r/\A[1-9][0-9]*\z/ and byte_size(value) <= max_digits,
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  @doc "The canonical `<ops>` string for `params`, without the signature."
  @spec canonical(Params.t()) :: String.t()
  def canonical(%Params{} = params) do
    @canonical_order
    |> Enum.flat_map(fn key ->
      case Map.fetch!(params, key) do
        nil -> []
        value -> ["#{key}_#{format_value(value)}"]
      end
    end)
    |> Enum.join(",")
  end

  defp format_value({a, b}), do: "#{a}:#{b}"
  defp format_value(value), do: to_string(value)

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  @doc """
  Whether this request may render at all: a valid signature, or (when
  unsigned URLs are allowed) every value on the allowlist. Checked before the
  item is even read, so a refused request costs no database or storage work.
  """
  @spec authorize(String.t(), Params.t()) :: :ok | error()
  def authorize(id, %Params{s: signature} = params) when is_binary(signature) do
    if Plug.Crypto.secure_compare(sign(id, canonical(params)), signature),
      do: :ok,
      else: {:error, :forbidden, "Invalid signature."}
  end

  def authorize(_id, %Params{} = params) do
    if allow_unsigned?(),
      do: check_allowlist(params),
      else: {:error, :forbidden, "This site only serves signed transform URLs."}
  end

  defp check_allowlist(params) do
    sizes = sizes()

    [
      {"w", params.w, sizes},
      {"h", params.h, sizes},
      {"ar", params.ar && format_value(params.ar), aspect_ratios()},
      {"q", params.q, unsigned_qualities()}
    ]
    |> Enum.find(fn {_key, value, allowed} -> value && value not in allowed end)
    |> case do
      nil -> :ok
      {key, value, allowed} -> off_list(key, value, Enum.join(allowed, ", "))
    end
  end

  defp off_list(key, value, allowed) do
    {:error, :bad_request,
     "#{key}_#{value} needs a signed URL. Unsigned URLs may use #{key}: #{allowed}."}
  end

  @doc """
  The signature for `canonical_ops` on item `id`: HMAC-SHA256 truncated to 16
  bytes, url-safe base64 without padding (22 characters).
  """
  @spec sign(String.t(), String.t(), binary() | nil) :: String.t()
  def sign(id, canonical_ops, key \\ nil) do
    :hmac
    |> :crypto.mac(:sha256, key || signing_key(), "#{id}/#{canonical_ops}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The HMAC key: `KILN_IMAGE_TRANSFORM_KEY` (`:signing_key`) verbatim, else
  derived from the endpoint's `secret_key_base` — so every deployment can sign
  its own URLs without configuring anything, and rotating `SECRET_KEY_BASE`
  invalidates URLs signed under the derived key.
  """
  @spec signing_key() :: binary()
  def signing_key do
    case Keyword.get(config(), :signing_key) do
      key when is_binary(key) and key != "" ->
        key

      _unset ->
        KilnCMSWeb.Endpoint.config(:secret_key_base)
        |> Plug.Crypto.KeyGenerator.generate("kiln image transform signing", length: 32)
    end
  end

  # ---------------------------------------------------------------------------
  # Versioning
  # ---------------------------------------------------------------------------

  @doc """
  The version token (`v`) for an item: FNV-1a 32-bit over
  `"<url>|<round(focal_x * 1000)>|<round(focal_y * 1000)>"`, as 8 hex digits.
  Accepts the item struct or any map with `url`/`focal_x`/`focal_y` (atom or
  string keys), so it works on a JSON:API payload too.
  """
  @spec version(map()) :: String.t()
  def version(item) do
    url = field(item, :url) || ""
    fx = milli(field(item, :focal_x))
    fy = milli(field(item, :focal_y))

    "#{url}|#{fx}|#{fy}"
    |> fnv1a32()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp milli(value) when is_number(value), do: round(value * 1000)
  defp milli(_missing), do: 500

  defp fnv1a32(string) do
    for <<byte <- string>>, reduce: 0x811C9DC5 do
      hash -> Bitwise.band(Bitwise.bxor(hash, byte) * 0x01000193, 0xFFFFFFFF)
    end
  end

  defp field(item, key) do
    case item do
      %{^key => value} -> value
      %{} -> Map.get(item, Atom.to_string(key))
    end
  end

  # ---------------------------------------------------------------------------
  # Planning
  # ---------------------------------------------------------------------------

  @doc """
  Plans the output for `params` against `item`'s recorded dimensions and
  focal point. `accept` is the request's `Accept` header, consulted only for
  `fm_auto`.

  `{:error, :unprocessable, _}` for an item that is not a transformable raster
  image (a document, a video, an image never processed) or whose source
  exceeds `max_source_pixels/0`.
  """
  @spec plan(map(), Params.t(), String.t() | nil) :: {:ok, Plan.t()} | error()
  def plan(item, %Params{} = params, accept \\ nil) do
    with {:ok, source_format} <- transformable(item) do
      sw = item.width
      sh = item.height
      {crop, {ow, oh}} = geometry(params, sw, sh, focal_point(item))
      format = output_format(params.fm, source_format, accept)
      quality = quality(format, params.q)
      {ext, content_type} = Map.fetch!(@format_info, format)

      focal =
        if crop && (params.crop || :focal) == :focal,
          do: focal_key(item),
          else: nil

      {:ok,
       %Plan{
         crop: crop,
         width: ow,
         height: oh,
         format: format,
         quality: quality,
         content_type: content_type,
         ext: ext,
         cache_key: cache_key(item.storage_key, crop, {ow, oh}, format, quality),
         focal: focal,
         vary_accept?: params.fm == :auto
       }}
    end
  end

  defp transformable(%{content_type: type, width: w, height: h} = item)
       when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    cond do
      not Map.has_key?(@source_formats, type) ->
        {:error, :unprocessable, "Only JPEG, PNG, WebP and GIF images can be transformed."}

      not is_binary(Map.get(item, :storage_key)) ->
        {:error, :unprocessable, "This image has no stored original."}

      w * h > max_source_pixels() ->
        {:error, :unprocessable, "This image is too large to transform."}

      true ->
        {:ok, Map.fetch!(@source_formats, type)}
    end
  end

  defp transformable(_item),
    do: {:error, :unprocessable, "Only processed raster images can be transformed."}

  @doc """
  The output geometry for `params` over a `sw`×`sh` source: the crop window
  (`{left, top, width, height}` in source pixels, `nil` for the whole frame)
  and the output `{width, height}`. Public for the builders' `srcset`, which
  needs to know how wide each candidate really comes out.
  """
  @spec geometry(Params.t(), pos_integer(), pos_integer(), {number(), number()}) ::
          {{non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()} | nil,
           {pos_integer(), pos_integer()}}
  def geometry(%Params{} = params, sw, sh, focal \\ {0.5, 0.5}) do
    dpr = params.dpr || 1
    anchor = anchor(params.crop || :focal, focal, sw, sh)

    params.w
    |> times(dpr)
    |> box(times(params.h, dpr), params.ar)
    |> within(max_dimension())
    |> shape(params.fit, sw, sh, anchor)
  end

  defp times(nil, _dpr), do: nil
  defp times(value, dpr), do: value * dpr

  defp shape({:box, bw, bh, _aspect}, :contain, sw, sh, _anchor),
    do: {nil, scaled(sw, sh, Enum.min([1, bw / sw, bh / sh]))}

  defp shape({:box, bw, bh, aspect}, _cover, sw, sh, anchor),
    do: cover(sw, sh, {bw, bh}, aspect, anchor)

  defp shape({:ratio, a, b}, _fit, sw, sh, anchor) do
    {crop, dims} = window(sw, sh, a / b, anchor)
    {whole_frame(crop, sw, sh), dims}
  end

  defp shape({:width, bw}, _fit, sw, sh, _anchor), do: {nil, scaled(sw, sh, min(1, bw / sw))}
  defp shape({:height, bh}, _fit, sw, sh, _anchor), do: {nil, scaled(sw, sh, min(1, bh / sh))}
  defp shape(:none, _fit, sw, sh, _anchor), do: {nil, {sw, sh}}

  # The target box, in output pixels, and the aspect ratio its crop window
  # takes. `ar` is width:height, so with a width the height is `w * b / a` and
  # vice versa — and the window uses `a / b` itself, not the rounded box's
  # ratio, so `ar_16:9` frames the same window at every width.
  defp box(w, h, _ar) when is_integer(w) and is_integer(h), do: {:box, w, h, w / h}
  defp box(w, nil, {a, b}) when is_integer(w), do: {:box, w, max(1, round(w * b / a)), a / b}
  defp box(nil, h, {a, b}) when is_integer(h), do: {:box, max(1, round(h * a / b)), h, a / b}
  defp box(nil, nil, {a, b}), do: {:ratio, a, b}
  defp box(w, nil, nil) when is_integer(w), do: {:width, w}
  defp box(nil, h, nil) when is_integer(h), do: {:height, h}
  defp box(nil, nil, nil), do: :none

  # `max_dimension` caps the OUTPUT, after `dpr`. A box is shrunk as a whole,
  # so `w_3000,ar_1:2,dpr_2` becomes 2000x4000 rather than a square: capping
  # each side on its own would change the aspect ratio that was asked for.
  defp within({:box, bw, bh, aspect}, max) when bw > max or bh > max do
    scale = max / max(bw, bh)
    {:box, max(1, round(bw * scale)), max(1, round(bh * scale)), aspect}
  end

  defp within({:width, w}, max), do: {:width, min(w, max)}
  defp within({:height, h}, max), do: {:height, min(h, max)}
  defp within(box, _max), do: box

  # Fill a `bw`×`bh` box: take the largest window of the box's aspect ratio
  # the source holds, anchored on `anchor`, then shrink it to the box — or,
  # when the window is smaller than the box, keep it at its own size rather
  # than upscale.
  defp cover(sw, sh, {bw, bh}, aspect, anchor) do
    {crop, {cw, ch}} = window(sw, sh, aspect, anchor)
    out = if bw <= cw and bh <= ch, do: {bw, bh}, else: {cw, ch}
    {whole_frame(crop, sw, sh), out}
  end

  defp window(sw, sh, aspect, {px, py}) do
    {cw, ch} =
      if sw / sh > aspect,
        do: {max(1, min(sw, round(sh * aspect))), sh},
        else: {sw, max(1, min(sh, round(sw / aspect)))}

    left = clamp(round(px - cw / 2), 0, sw - cw)
    top = clamp(round(py - ch / 2), 0, sh - ch)
    {{left, top, cw, ch}, {cw, ch}}
  end

  defp whole_frame({0, 0, sw, sh}, sw, sh), do: nil
  defp whole_frame(crop, _sw, _sh), do: crop

  defp scaled(sw, sh, scale), do: {max(1, round(sw * scale)), max(1, round(sh * scale))}

  defp anchor(:focal, {fx, fy}, sw, sh), do: {fx * sw, fy * sh}
  defp anchor(:center, _focal, sw, sh), do: {sw / 2, sh / 2}
  defp anchor(:top, _focal, sw, _sh), do: {sw / 2, 0}
  defp anchor(:bottom, _focal, sw, sh), do: {sw / 2, sh}
  defp anchor(:left, _focal, _sw, sh), do: {0, sh / 2}
  defp anchor(:right, _focal, sw, sh), do: {sw, sh / 2}

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp focal_point(item) do
    {unit(Map.get(item, :focal_x)), unit(Map.get(item, :focal_y))}
  end

  defp unit(value) when is_number(value), do: value |> max(0.0) |> min(1.0)
  defp unit(_missing), do: 0.5

  @doc false
  # The focal point a focal crop was anchored on, as `KilnCMS.CMS.MediaDerivative`
  # records it — so `Derivatives` can tell which cached crops a move invalidated.
  def focal_key(item) do
    {fx, fy} = focal_point(item)
    "#{milli(fx)}:#{milli(fy)}"
  end

  defp output_format(nil, source, _accept), do: source

  defp output_format(:auto, source, accept) do
    accept = accept || ""

    cond do
      auto_avif?() and String.contains?(accept, "image/avif") -> :avif
      String.contains?(accept, "image/webp") -> :webp
      # A client that can't take WebP can't take a WebP *source* either.
      source == :webp -> :png
      true -> source
    end
  end

  defp output_format(format, _source, _accept), do: format

  # PNG has no quality knob (see `ImageProcessor`'s `@default_quality`), so it
  # carries none — and `q_50,fm_png` shares a derivative with `fm_png`.
  defp quality(:png, _q), do: nil
  defp quality(_format, q) when is_integer(q), do: q
  defp quality(format, nil), do: ImageProcessor.quality(format)

  # Keyed on what is RENDERED, not on what was asked: `w_800,dpr_2` and
  # `w_1600` are one derivative, and so is every width past the source's own.
  # A flat, basename-only storage key, because `Storage.Local` refuses paths.
  defp cache_key(storage_key, crop, {w, h}, format, quality) do
    crop = if crop, do: crop |> Tuple.to_list() |> Enum.join(":"), else: "-"

    digest =
      :crypto.hash(:sha256, "#{@engine}|#{storage_key}|#{crop}|#{w}x#{h}|#{format}|#{quality}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "t-#{digest}"
  end

  # ---------------------------------------------------------------------------
  # Building URLs
  # ---------------------------------------------------------------------------

  @doc """
  A transform URL path for `item`.

  Options: `:width`, `:height`, `:aspect_ratio` (`{a, b}` or `"a:b"`), `:dpr`,
  `:fit`, `:crop`, `:format`, `:quality` (`:height` and `:aspect_ratio` are
  exclusive, as in the grammar). The version pin is included whenever
  the item has a `url`. `item` may be the struct or a JSON map (`"id"`,
  `"url"`, `"focal_x"`, `"focal_y"`).

  Signed by default with this deployment's key, so any value within the hard
  limits works — which is what Kiln's own templates want. `sign: false`
  builds an unsigned URL instead, snapping `:width`/`:height` up to the
  allowlist (`snap: false` to leave them alone).
  """
  @spec url(map(), keyword()) :: String.t()
  def url(item, opts \\ []) do
    if Keyword.get(opts, :height) && Keyword.get(opts, :aspect_ratio),
      do: raise(ArgumentError, "pass :height or :aspect_ratio, not both")

    sign? = Keyword.get(opts, :sign, true)
    snap? = Keyword.get(opts, :snap, not sign?)

    params = %Params{
      w: opts |> Keyword.get(:width) |> maybe_snap(snap?),
      h: opts |> Keyword.get(:height) |> maybe_snap(snap?),
      ar: opts |> Keyword.get(:aspect_ratio) |> ratio(),
      dpr: Keyword.get(opts, :dpr),
      fit: Keyword.get(opts, :fit),
      crop: Keyword.get(opts, :crop),
      fm: Keyword.get(opts, :format),
      q: Keyword.get(opts, :quality),
      # Only with a `url` to hash: a version of nothing would never match the
      # server's, and a mismatched pin is worse than none (same lifetime, and
      # it reads as though it should be immutable).
      v: if(field(item, :url), do: version(item))
    }

    id = field(item, :id)
    ops = canonical(params)
    ops = if sign?, do: "#{ops},s_#{sign(id, ops, Keyword.get(opts, :key))}", else: ops
    "/media/#{id}/t/#{ops}"
  end

  defp maybe_snap(nil, _snap?), do: nil
  defp maybe_snap(value, false), do: value
  defp maybe_snap(value, true), do: snap(value)

  @doc "Snaps a size up to the next allowlisted one (the largest, past the top)."
  @spec snap(pos_integer()) :: pos_integer()
  def snap(value) do
    sizes = sizes()
    Enum.find(sizes, List.last(sizes), &(&1 >= value))
  end

  defp ratio(nil), do: nil
  defp ratio({a, b}), do: {a, b}

  defp ratio(string) when is_binary(string) do
    [a, b] = String.split(string, ":")
    {String.to_integer(a), String.to_integer(b)}
  end

  @doc """
  A `srcset` of transform URLs for `item` at each of `widths` (default: the
  allowlisted sizes from 256 up), plus the options `url/2` takes. Pass
  `:aspect_ratio` rather than `:height` for a cropped set — a fixed height
  would give every candidate a different shape, which a `srcset` must not.

  Each candidate is described by the width it can really render at:
  `min(w, widest)`, where `widest` is the item's width, or for an aspect
  ratio `a:b` the width of the largest `a:b` window, `min(width,
  round(height * a / b))`. Candidates past `widest` would all render at it,
  so only the first of them is kept. The SDK builders use the same rule, so
  all three produce the same attribute. `nil` for an item that cannot be
  transformed (or when no width is known).
  """
  @spec srcset(map(), [pos_integer()] | nil, keyword()) :: String.t() | nil
  def srcset(item, widths \\ nil, opts \\ []) do
    sw = field(item, :width)
    sh = field(item, :height)

    if is_integer(sw) and sw > 0 and is_integer(sh) and sh > 0 do
      ar = opts |> Keyword.get(:aspect_ratio) |> ratio()
      widest = widest(sw, sh, ar)
      snap? = Keyword.get(opts, :snap, not Keyword.get(opts, :sign, true))
      opts = Keyword.delete(opts, :height)

      (widths || Enum.filter(sizes(), &(&1 >= 256)))
      |> Enum.map(&maybe_snap(&1, snap?))
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&{&1, min(&1, widest)})
      |> Enum.uniq_by(fn {_w, described} -> described end)
      |> Enum.map_join(", ", fn {w, described} ->
        "#{url(item, Keyword.merge(opts, width: w, snap: false))} #{described}w"
      end)
    end
  end

  defp widest(sw, _sh, nil), do: sw
  defp widest(sw, sh, {a, b}), do: min(sw, max(1, round(sh * a / b)))

  @doc "Content type for a planned output format."
  @spec content_type(atom()) :: String.t()
  def content_type(format), do: @format_info |> Map.fetch!(format) |> elem(1)
end
