defmodule KilnCMS.ImageProcessor do
  @moduledoc """
  Reads intrinsic dimensions and generates downscaled responsive variants from
  an uploaded image, via libvips (Vix/Image).

  Degrades gracefully: anything that isn't a readable raster image returns
  `{:error, _}`, and callers fall back to storing the original only (no
  dimensions, no variants). Variants are written to temp files; the caller is
  responsible for persisting and cleaning them up.
  """

  require Logger

  # Responsive target widths. A variant is only produced when the source is
  # wider than the target (we never upscale).
  @targets [thumb: 400, medium: 1024]

  # Focal-aware cropped variants: `{label, {width, height}}`. The crop window
  # takes the target's aspect ratio, centers on the focal point (clamped to
  # the source bounds), then downscales — never upscales. Skipped when the
  # source is smaller than the target box.
  @cropped [card: {800, 450}]

  @typedoc """
  A written variant. `label` is the responsive/crop name for the **source**
  format and `"<label>.<format>"` for every alternate one, so one map key names
  exactly one file; `content_type` is what a `<picture>` `<source type=…>` needs.
  """
  @type variant :: %{
          label: String.t(),
          path: Path.t(),
          width: pos_integer,
          height: pos_integer,
          format: atom(),
          content_type: String.t(),
          ext: String.t()
        }
  @type focal :: %{x: float(), y: float()}

  # Alternate encodings every variant is also written in (#473). WebP is on by
  # default — 25-35% smaller than JPEG at equal quality, universally supported
  # for a decade. AVIF is opt-in because encoding it costs roughly an order of
  # magnitude more CPU per image, which is a real bill on a bulk regeneration.
  #
  #     config :kiln_cms, :image_variants, formats: [:webp, :avif]
  @default_formats [:webp]

  # Per-format encoder quality, for the **lossy** formats only. libvips' own
  # defaults are conservative (JPEG 75, WebP 75); these are the widely-used
  # "visually lossless for web" settings. AVIF's scale is not JPEG's — 50 there
  # is roughly WebP 80.
  #
  # PNG and GIF are absent on purpose: libvips has no quality knob for either
  # (PNG is `compression`, GIF is palette quantisation), and `Image.write`
  # discards `:quality` for them outright. Offering a `png_quality` setting that
  # silently does nothing is worse than not offering one.
  @default_quality [webp: 82, avif: 50, jpg: 82]

  # Extension + content type per output format.
  @format_info %{
    webp: {".webp", "image/webp"},
    avif: {".avif", "image/avif"},
    jpg: {".jpg", "image/jpeg"},
    png: {".png", "image/png"},
    gif: {".gif", "image/gif"}
  }

  @doc """
  Alternate formats each variant is additionally written in (default `[:webp]`).

  Unknown names are dropped rather than raising: a typo in deployment config
  should cost the site its WebP variants, not its uploads.
  """
  @spec variant_formats() :: [atom()]
  def variant_formats do
    :kiln_cms
    |> Application.get_env(:image_variants, [])
    |> Keyword.get(:formats, @default_formats)
    |> List.wrap()
    |> Enum.filter(&is_map_key(@format_info, &1))
  end

  # The config key per lossy format, as literals — interpolating
  # `:"#{format}_quality"` would mint an atom from a value that reaches here via
  # a stored variant key.
  @quality_keys %{webp: :webp_quality, avif: :avif_quality, jpg: :jpg_quality}

  @doc """
  Encoder quality for `format`, from `:image_variants` config.

  Clamped to the 1..100 integer range `Image.write/3` accepts. A misconfigured
  value (`"82"` straight out of `System.get_env/1` is the obvious one) falls
  back to the default rather than being passed through: `Image.write` rejects
  anything outside that range, and since a rejected write produces *no* variant
  the alternative is a config typo silently emptying the library.
  """
  @spec quality(atom()) :: pos_integer()
  def quality(format) do
    configured = Application.get_env(:kiln_cms, :image_variants, [])
    default = Keyword.get(@default_quality, format, 82)

    with {:ok, key} <- Map.fetch(@quality_keys, format),
         value when is_integer(value) and value in 1..100 <-
           Keyword.get(configured, key, default) do
      value
    else
      _ -> default
    end
  end

  @doc """
  The content type of a stored variant, given its map key. Alternate formats
  carry their format as a suffix (`"thumb.webp"`); the bare label is the
  source format, whose type the caller already knows from the item.
  """
  @spec variant_content_type(String.t()) :: String.t() | nil
  def variant_content_type(label) when is_binary(label) do
    case String.split(label, ".", parts: 2) do
      [_base, format] -> @format_info |> Map.get(safe_format(format)) |> elem_or_nil()
      _bare -> nil
    end
  end

  defp elem_or_nil(nil), do: nil
  defp elem_or_nil({_ext, content_type}), do: content_type

  # Only ever called with a suffix this module itself wrote, but the value
  # arrives from a stored JSON key, so resolve it against the known set rather
  # than minting an atom.
  defp safe_format(name) do
    Enum.find(Map.keys(@format_info), &(to_string(&1) == name))
  end

  @doc """
  The **base** responsive label of a stored variant key, with any format suffix
  removed — `"card.webp"` is still the `card` crop. Every rule keyed on a label
  (the `srcset` exclusions, most of all) has to ask this rather than compare the
  key, or an alternate encoding of an excluded variant slips back in.
  """
  @spec base_label(String.t()) :: String.t()
  def base_label(label) when is_binary(label), do: label |> String.split(".") |> hd()

  @doc """
  Labels of the focal-aware **cropped** variants. Cropped variants change the
  aspect ratio, so responsive `srcset` builders must exclude them — a browser
  picking the crop for a plain `<img>` would show the wrong framing.
  """
  @spec cropped_labels() :: [String.t()]
  def cropped_labels, do: Enum.map(@cropped, fn {label, _dims} -> to_string(label) end)

  # Canonical {extension, content_type} per allowed libvips loader. Deny-by-default:
  # anything else (svgload, tiffload, pdfload, …) is rejected.
  @allowed_formats %{
    "jpegload" => {".jpg", "image/jpeg"},
    "pngload" => {".png", "image/png"},
    "webpload" => {".webp", "image/webp"},
    "gifload" => {".gif", "image/gif"}
  }

  # Decompression-bomb guard: a small compressed file can expand to a huge
  # pixel buffer (a 10MB PNG can decode to multiple GB). Opening is lazy in
  # libvips — dimensions come from the header — so this cap is checked before
  # any full decode (metadata strip, variants) can happen. 50MP comfortably
  # covers real photography. Runtime-configurable for tests/deployments.
  @default_max_pixels 50_000_000

  defp max_pixels do
    :kiln_cms |> Application.get_env(:media, []) |> Keyword.get(:max_pixels, @default_max_pixels)
  end

  @doc """
  Returns `{:ok, %{ext: ".png", content_type: "image/png"}}` when `path` is a
  readable raster image in an allowed format, deriving the canonical extension and
  content-type from the actual bytes (not the client-supplied name/MIME). Rejects
  anything else with `{:error, _}`.
  """
  @spec validate_upload(Path.t()) ::
          {:ok, %{ext: String.t(), content_type: String.t()}} | {:error, term}
  def validate_upload(path) when is_binary(path) do
    with {:ok, image} <- Image.open(path),
         {:ok, loader} <- Vix.Vips.Image.header_value(image, "vips-loader"),
         {:ok, {ext, content_type}} <- allowed_format(loader),
         :ok <- within_pixel_limit(image) do
      {:ok, %{ext: ext, content_type: content_type}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_image}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.validate_upload failed for #{path}: #{inspect(e)}")
      {:error, :invalid_image}
  end

  # Total pixels across all frames (animated GIF/WebP multiply the buffer).
  defp within_pixel_limit(image) do
    frames =
      case Vix.Vips.Image.header_value(image, "n-pages") do
        {:ok, n} when is_integer(n) and n > 0 -> n
        _ -> 1
      end

    if Image.width(image) * Image.height(image) * frames <= max_pixels(),
      do: :ok,
      else: {:error, :too_many_pixels}
  end

  defp allowed_format(loader) when is_binary(loader) do
    case Map.fetch(@allowed_formats, String.replace_suffix(loader, "_buffer", "")) do
      {:ok, fmt} -> {:ok, fmt}
      :error -> {:error, :unsupported_format}
    end
  end

  defp allowed_format(_), do: {:error, :unsupported_format}

  @doc """
  Re-encodes `path` (already validated, with canonical `ext`) to a temp file
  with **all metadata stripped** — EXIF/GPS, camera info, and the original
  client filename. Returns `{:ok, stripped_tmp_path}`; the caller owns the temp
  file. On any failure returns `{:error, reason}` so the caller can fall back to
  storing the original. Multi-page/animated sources (GIF/WebP) are opened with
  all frames so animation is preserved.

  Privacy (#215): uploaded photos commonly carry GPS and device metadata. Both
  the stored original and (via re-fetch in `Media.VariantWorker`) its variants
  are sourced from this stripped copy.
  """
  # `tmp` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File.rm traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  @spec strip_metadata(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term}
  def strip_metadata(path, ext) when is_binary(path) and is_binary(ext) do
    tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-stripped#{ext}")

    with {:ok, image} <- open_all_pages(path),
         {:ok, stripped} <- strip(image),
         {:ok, _} <- Image.write(stripped, tmp) do
      {:ok, tmp}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.strip_metadata failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  # Drop every header field (all EXIF incl. GPS/device/filename, plus XMP/IPTC)
  # so libvips can't regenerate the EXIF blob from leftover `exif-ifd*` fields on
  # save. We remove fields directly rather than via the `strip` save flag (a
  # silent no-op on current libvips) or `minimize_metadata` (which first *reads*
  # EXIF and errors out on a thumbnail's regenerated `:invalid_exif` blob).
  defp strip(image), do: Image.remove_metadata(image, [])

  # Prefer loading every frame (animated GIF/WebP) so stripping doesn't flatten
  # animation; single-page loaders (JPEG/PNG) reject `pages:` so fall back.
  defp open_all_pages(path) do
    case Image.open(path, pages: :all) do
      {:ok, image} -> {:ok, image}
      _ -> Image.open(path)
    end
  end

  @doc """
  Analyzes `path` and writes any applicable variants (with extension `ext`,
  e.g. `".png"`) to the temp dir: the downscaled responsive set plus the
  focal-aware crops (see `@cropped`), cropped around `focal` (fractions of
  the source dimensions, default center). Returns the dimensions and variant
  temp files.
  """
  @spec process(Path.t(), String.t(), focal()) ::
          {:ok,
           %{
             width: pos_integer,
             height: pos_integer,
             variants: [variant],
             failed: [String.t()]
           }}
          | {:error, term}
  def process(path, ext, focal \\ %{x: 0.5, y: 0.5}) do
    with {:ok, image} <- Image.open(path),
         # Re-checked here, not just at upload: bulk regeneration (#473) decodes
         # every *existing* original, so an operator who lowers `:max_pixels` to
         # control cost would otherwise still pay full price on every old file.
         :ok <- within_pixel_limit(image) do
      width = Image.width(image)
      height = Image.height(image)

      {full, failed_full} = build_full(image, ext)
      {responsive, failed_responsive} = build_variants(image, width, ext)
      {crops, failed_crops} = build_crops(image, width, height, focal, ext)

      variants = responsive ++ crops ++ full

      # Every entry is a `"<label>.<format>"` key (#1036) — `build_full`'s own
      # `alternates/2` and `encodings/3` (shared by `thumb/4` and
      # `focal_crop/7`) both key their failures the same way a written variant
      # is keyed, so `Regeneration.current?/1` can look either map up by the
      # identical key. Per-{label, format} rather than a bare format list
      # (#1000 tracked only `full`'s) because a format's encoder can plausibly
      # reject one label's dimensions and accept another's — collapsing that
      # to "format X failed" would excuse a label whose own write actually
      # succeeds, or would fail to re-attempt one whose failure was really
      # size-specific to a different label.
      failed = failed_full ++ failed_responsive ++ failed_crops

      {:ok, %{width: width, height: height, variants: variants, failed: failed}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Applies a geometric edit to the (validated) image at `path`, writing the
  result to a temp file with extension `ext`. Returns the temp path and the
  resulting dimensions; the caller owns the temp file. Metadata is stripped
  on the way out, like every other write in this module.
  """
  # `tmp` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File.rm traversal warning is a false positive (same as strip_metadata/2).
  # sobelow_skip ["Traversal.FileModule"]
  @spec transform(
          Path.t(),
          String.t(),
          :rotate_left | :rotate_right | :flip_horizontal | :flip_vertical
        ) ::
          {:ok, %{path: Path.t(), width: pos_integer, height: pos_integer}} | {:error, term}
  def transform(path, ext, op)
      when op in [:rotate_left, :rotate_right, :flip_horizontal, :flip_vertical] do
    tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-edit#{ext}")

    with {:ok, image} <- Image.open(path),
         {:ok, edited} <- apply_op(image, op),
         {:ok, edited} <- strip(edited),
         {:ok, _} <- Image.write(edited, tmp) do
      {:ok, %{path: tmp, width: Image.width(edited), height: Image.height(edited)}}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.transform failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  defp apply_op(image, :rotate_left), do: Image.rotate(image, -90.0)
  defp apply_op(image, :rotate_right), do: Image.rotate(image, 90.0)
  defp apply_op(image, :flip_horizontal), do: Image.flip(image, :horizontal)
  defp apply_op(image, :flip_vertical), do: Image.flip(image, :vertical)

  # Each builder returns `{variants, failed_keys}` (#1036) — `merge_built/1`
  # concatenates both halves across every target the builder attempted, the
  # same shape `build_full/2` already reported for the full-size case.
  defp build_variants(image, src_width, ext) do
    @targets
    |> Enum.filter(fn {_label, target} -> target < src_width end)
    |> Enum.map(fn {label, target} -> thumb(image, label, target, ext) end)
    |> merge_built()
  end

  # Focal-aware crops: a window with the target's aspect ratio, as large as the
  # source allows, centered on the focal point and clamped to the bounds — the
  # subject stays in frame wherever it sits.
  defp build_crops(image, w, h, focal, ext) do
    @cropped
    |> Enum.filter(fn {_label, {tw, th}} -> w >= tw and h >= th end)
    |> Enum.map(fn {label, {tw, th}} ->
      focal_crop(image, w, h, focal, label, {tw, th}, ext)
    end)
    |> merge_built()
  end

  defp merge_built(results) do
    Enum.reduce(results, {[], []}, fn {variants, failed}, {acc_variants, acc_failed} ->
      {acc_variants ++ variants, acc_failed ++ failed}
    end)
  end

  defp focal_crop(image, w, h, focal, label, {tw, th}, ext) do
    aspect = tw / th

    {crop_w, crop_h} =
      if w / h > aspect,
        do: {round(h * aspect), h},
        else: {w, round(w / aspect)}

    left = clamp(round(focal.x * w - crop_w / 2), 0, w - crop_w)
    top = clamp(round(focal.y * h - crop_h / 2), 0, h - crop_h)

    with {:ok, cropped} <- Image.crop(image, left, top, crop_w, crop_h),
         {:ok, resized} <- Image.thumbnail(cropped, tw),
         {:ok, resized} <- strip(resized) do
      encodings(resized, label, ext)
    else
      # The crop/resize pipeline itself failing is "this run failing", the same
      # as `build_full/2`'s unreadable-source case — not "will never encode",
      # which is `encodings/3`'s per-format concern. Reporting nothing here
      # keeps the item repairable by a later run instead of freezing it on a
      # transient failure.
      _ -> {[], []}
    end
  end

  # A full-size re-encode, in the ALTERNATE formats only (#473).
  #
  # Without this a `<picture>` silently caps delivered resolution. Per the HTML
  # spec a matching `<source>` *replaces* the `<img>`'s srcset — the `<img>` is
  # never consulted — so a WebP-capable browser would only ever see the
  # generated downscales, whose widest is 1024w. A 1600px original would render
  # from `medium.webp`, and an original under 1024px (which produces no `medium`
  # at all) from the 400w thumb, upscaled. Every content image would quietly get
  # worse on exactly the browsers this feature exists to serve.
  #
  # There is deliberately no source-format `full`: that is the original, which
  # `Presentation.srcset/1` already appends.
  defp build_full(image, ext) do
    source = source_format(ext)

    # Stripped for the same reason `thumb/4` and `focal_crop/7` strip (#215/#919):
    # this is the one write path that encodes straight from the OPENED SOURCE
    # rather than from a `thumbnail/2` result, so it is the most likely of the
    # three to be handed an un-stripped original — a pre-#215 upload, or one
    # where `MediaLive.stripped_source/2` fell back to `{path, false}`. Without
    # it, `mix kiln.media.regenerate_variants` published a full-resolution
    # `full.webp` carrying the original's GPS/EXIF, referenced from the
    # `<source srcset>` of every page showing that image.
    case strip(image) do
      {:ok, stripped} -> alternates(stripped, source)
      # Unreadable is not "will never encode" — it is this run failing. Report no
      # failures so the item stays repairable by a later run.
      _unreadable -> {[], []}
    end
  end

  defp alternates(_image, :gif), do: {[], []}

  defp alternates(image, source) do
    variant_formats()
    |> Enum.reject(&(&1 == source))
    |> Enum.map(fn format ->
      {extension, _type} = Map.fetch!(@format_info, format)
      key = "full.#{format}"
      {key, write(image, key, format, extension)}
    end)
    |> split_written()
  end

  # Shared by `alternates/2` and `encodings/3`: pair each write's own key with
  # its result, then split into the written variants and the keys that
  # weren't (#1036) — a `nil` from `write/4` is a real per-format encode
  # failure, not a hole to silently drop.
  defp split_written(keyed) do
    keyed
    |> Enum.split_with(fn {_key, written} -> written end)
    |> then(fn {ok, failed} ->
      {Enum.map(ok, &elem(&1, 1)), Enum.map(failed, &elem(&1, 0))}
    end)
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp thumb(image, label, target, ext) do
    with {:ok, resized} <- Image.thumbnail(image, target),
         # Defense-in-depth: strip metadata on variants too, so they never carry
         # EXIF/GPS even if a future caller processes an un-stripped original (#215).
         {:ok, resized} <- strip(resized) do
      encodings(resized, label, ext)
    else
      # Same reasoning as `focal_crop/7`'s else clause: a resize/strip failure
      # is this run failing, not a permanent per-format verdict.
      _ -> {[], []}
    end
  end

  # Write one already-resized image in the source format and in every configured
  # alternate (#473).
  #
  # The source format is always written and always keyed by the bare label: it
  # is the `<img src>` fallback, and every stored `variants` map that predates
  # this — plus every `srcset` built from one — is keyed that way. Alternates
  # take a `"<label>.<format>"` key so one map key still names one file.
  #
  # A source format that is *also* a configured alternate (a WebP upload with
  # WebP variants) is written once, under the bare label: two identical files
  # under two keys would double storage and put the same bytes in a `<picture>`
  # twice.
  #
  # Animated sources are the exception: `process/3` opens a single page, so a
  # GIF's variants are already flattened stills. Transcoding those to WebP would
  # spend encoder time producing a *second* still of an image whose animation is
  # the point, so alternates are skipped and the source-format variant stands.
  defp encodings(image, label, ext) do
    source = source_format(ext)

    alternates =
      if source == :gif, do: [], else: Enum.reject(variant_formats(), &(&1 == source))

    [{source, to_string(label), ext} | Enum.map(alternates, &alternate(&1, label))]
    |> Enum.map(fn {format, key, extension} -> {key, write(image, key, format, extension)} end)
    |> split_written()
  end

  defp alternate(format, label) do
    {extension, _content_type} = Map.fetch!(@format_info, format)
    {format, "#{label}.#{format}", extension}
  end

  # `tmp` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File.rm traversal warning is a false positive (as in strip_metadata/2).
  # sobelow_skip ["Traversal.FileModule"]
  defp write(image, key, format, ext) do
    tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-#{key}#{ext}")

    case Image.write(image, tmp, quality: quality(format)) do
      {:ok, _} ->
        %{
          label: key,
          path: tmp,
          width: Image.width(image),
          height: Image.height(image),
          format: format,
          content_type: content_type(format),
          ext: ext
        }

      {:error, reason} ->
        # One format failing (no AVIF encoder in this libvips build, say) must
        # not cost the others — including the source-format fallback. Logged,
        # because the silent version of this is "the library lost its variants
        # and nobody knows why".
        Logger.warning("ImageProcessor could not write #{key} as #{format}: #{inspect(reason)}")
        File.rm(tmp)
        nil
    end
  end

  defp content_type(format) do
    {_ext, content_type} = Map.fetch!(@format_info, format)
    content_type
  end

  @doc """
  The alternate formats a full-size re-encode would write for a source of this
  content type — every configured variant format except the source's own.

  Public so `KilnCMS.Media.Regeneration` can answer "would a run add anything to
  this item?" without re-deriving the rule (#919). Empty for an animated source:
  a GIF gets no alternates by design, since its variants are flattened stills.

  This is the same set `build_full/2` writes, expressed once, so the two cannot
  disagree about whether an item with no variants is already up to date.
  """
  @spec full_alternates(String.t() | nil) :: [atom()]
  def full_alternates("image/gif"), do: []

  def full_alternates(content_type) do
    source =
      Enum.find_value(@format_info, :jpg, fn {format, {_ext, type}} ->
        if type == content_type, do: format
      end)

    Enum.reject(variant_formats(), &(&1 == source))
  end

  # The format a source extension names, for deduping against the alternates.
  # `.jpeg` and `.jpg` are the same encoder.
  defp source_format(ext) do
    case String.downcase(ext) do
      e when e in [".jpg", ".jpeg"] -> :jpg
      ".png" -> :png
      ".webp" -> :webp
      ".avif" -> :avif
      ".gif" -> :gif
      _other -> :jpg
    end
  end
end
