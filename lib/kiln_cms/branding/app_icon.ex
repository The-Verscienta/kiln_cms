defmodule KilnCMS.Branding.AppIcon do
  @moduledoc """
  Verifies that a site's `app_icon_url` really is a square raster image big
  enough to install with (#629), and reports the edge length so the manifest can
  declare `icons[].sizes` honestly.

  ## Why this cannot just reuse `logo_url`

  `icons[].sizes` is a **declaration**, and Chromium's installability check
  believes it. A manifest that says `512x512` about a 300×80 wordmark does not
  degrade — the install prompt disappears, and nothing tells the operator why.
  So the rule here is: an icon is used only when this module has *seen* it and
  can name its size. Anything else falls back to the stock KilnCMS mark, which
  is worse-looking and correct.

  ## Where the bytes come from

  Two kinds of URL, because branding fields accept both:

    * a path or same-origin URL (`/uploads/…`) — read through
      `KilnCMS.Storage`, which is where uploads actually live and works
      identically on local disk and S3;
    * anything absolute — fetched with `KilnCMS.SafeFetch`, because this is an
      operator-supplied URL that the *server* dials. Without the
      resolve-once-connect-to-the-literal treatment, "set your icon URL" is a
      request-forgery primitive pointed at the metadata service.

  ## PNG and JPEG only

  Narrower than the media library, because of iOS: the `apple-touch-icon` link
  has no format negotiation and no second candidate, and iOS answers a WebP or
  GIF there by ignoring it and using a screenshot of the page instead. The
  format is read from the decoded bytes, never from the URL's extension.

  ## Failing is not an error

  `verify/1` returns `{:ok, size}` or `{:error, reason}`, and a caller is
  expected to store the URL either way with the size left `nil`. An operator
  whose CDN is briefly down should not have their icon setting rejected; they
  should keep the stock icon until the next save succeeds. The reason exists so
  the settings page can say which of the four things went wrong, rather than
  "invalid".
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  require Logger

  alias KilnCMS.CMS.Validations.BrandTokens
  alias KilnCMS.ImageProcessor
  alias KilnCMS.SafeFetch
  alias KilnCMS.Storage

  # A maskable icon is drawn with a 40% safe zone and the largest declared size
  # a manifest needs is 512, so anything smaller cannot fill the set without
  # upscaling — which is exactly the "looks like a bug" outcome the stock icon
  # avoids.
  @min_edge 512

  # Bounded because the bytes are operator-supplied and fetched by the server.
  # 4 MB rather than a tighter figure because a *lossless* 1024×1024 PNG
  # straight out of a design tool routinely clears 2 MB, and an operator whose
  # perfectly good icon is refused has no way to tell that size was the reason
  # unless the cap is both generous and named (`:too_large`).
  # See `check_format/2`: narrowed to what iOS will render as an
  # `apple-touch-icon`, since that surface has no fallback.
  @icon_types ~w(image/png image/jpeg)

  @max_bytes 4 * 1024 * 1024
  @max_mb div(@max_bytes, 1024 * 1024)

  @typedoc "Why an icon could not be used. The settings page renders each."
  @type reason ::
          :not_configured
          | :not_allowed
          | :not_in_media_library
          | :unreachable
          | :too_large
          | :not_an_image
          | {:not_square, pos_integer(), pos_integer()}
          | {:too_small, pos_integer()}

  @doc "The smallest square edge an installable icon may have."
  @spec min_edge() :: pos_integer()
  def min_edge, do: @min_edge

  @doc """
  Read `url` and return `{:ok, edge}` when it is a square raster image of at
  least `min_edge/0` pixels.
  """
  @spec verify(String.t() | nil) :: {:ok, pos_integer()} | {:error, reason()}
  def verify(url) when is_binary(url) do
    case String.trim(url) do
      "" -> {:error, :not_configured}
      trimmed -> check_policy(trimmed)
    end
  end

  def verify(_absent), do: {:error, :not_configured}

  # The policy check lives HERE, not in the caller. This function dials an
  # operator-supplied URL from the server, so "is this a URL we are willing to
  # dial" has to be a property of the mechanism — a second caller (a
  # re-verification job, an import) must not be able to reach the fetch by
  # forgetting a guard. `BrandTokens` stays the single definition of the rule;
  # this only asks it.
  defp check_policy(url) do
    if BrandTokens.allowed_image_url?(url) do
      url |> read() |> measure()
    else
      {:error, :not_allowed}
    end
  end

  @doc """
  Human-readable explanation of a `verify/1` failure, for the branding form.

  Deliberately specific: "invalid image" sends an operator to re-export a file
  that was fine, when the actual answer was that their CDN 404s or that the
  image is 400px.
  """
  @spec explain(reason()) :: String.t()
  def explain(:not_configured), do: gettext("No app icon set.")

  def explain(:not_allowed),
    do:
      gettext(
        "That URL is not allowed by the site's image policy. Upload the icon to the media library, or ask an operator to add the host to CSP_IMG_SRC."
      )

  def explain(:not_in_media_library),
    do:
      gettext(
        "A same-origin icon has to come from the media library. Upload it there and use the /uploads/… path it gives you."
      )

  def explain(:too_large),
    do: gettext("An app icon must be under %{max} MB; that one is larger.", max: @max_mb)

  def explain(:unreachable),
    do: gettext("Couldn't fetch that URL. Check it is publicly reachable, then save again.")

  def explain(:not_an_image),
    do: gettext("An app icon must be a PNG or JPEG image.")

  def explain({:not_square, width, height}),
    do:
      gettext("An app icon must be square; that one is %{width}×%{height}.",
        width: width,
        height: height
      )

  def explain({:too_small, edge}),
    do:
      gettext("An app icon must be at least %{min}×%{min}; that one is %{edge}×%{edge}.",
        min: @min_edge,
        edge: edge
      )

  # ── reading ────────────────────────────────────────────────────────────────

  # Written to a temp file rather than measured in memory: `Image.open/1` wants
  # a path, and libvips reads dimensions from the header without decoding the
  # pixels — so this never materializes the full bitmap of whatever was fetched.
  #
  # The path is built entirely here from `System.tmp_dir!/0` and a VM-unique
  # integer; no part of the operator-supplied URL reaches it, which is what the
  # traversal check is looking for.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(url) do
    with {:ok, bytes} <- bytes(url) do
      path = Path.join(System.tmp_dir!(), "kiln-app-icon-#{:erlang.unique_integer([:positive])}")

      case File.write(path, bytes) do
        :ok -> {:ok, path}
        {:error, _reason} -> {:error, :unreachable}
      end
    end
  end

  # Same-origin paths are storage keys, not URLs to dial. Fetching our own
  # `/uploads/…` over HTTP would make a site behind basic auth or a private
  # network unable to verify its own icon, and would loop back through the
  # proxy for no reason.
  #
  # Read as a RANGE, not with `Storage.fetch/1`. `fetch/1` pulls the whole
  # object onto the heap, and the media library accepts uploads up to 500 MB —
  # so an admin pasting the path of a video would allocate half a gigabyte
  # inside a synchronous settings save. One ranged read caps the bytes and
  # reports the true total, which is also how the size limit is enforced on
  # this branch at all.
  defp bytes("/" <> _rest = path) do
    with {:ok, key} <- storage_key(path) do
      case Storage.fetch_range(key, 0, @max_bytes - 1) do
        {:ok, %{total: total}} when total > @max_bytes ->
          {:error, :too_large}

        {:ok, %{bytes: bytes}} when byte_size(bytes) > 0 ->
          {:ok, bytes}

        _missing ->
          {:error, :unreachable}
      end
    end
  end

  defp bytes(url) do
    case SafeFetch.get(url,
           max_bytes: @max_bytes,
           # Sibling callers follow redirects and icon CDNs rely on them —
           # a bucket that 301s to its alias is a working URL in a browser, and
           # reporting it `:unreachable` is unactionable. Every hop is
           # re-checked by SafeFetch against SafeUrl.
           max_redirects: 3,
           # Tighter than SafeFetch's defaults on purpose: this runs
           # synchronously inside a LiveView save, so the worst case an admin
           # can wait is what these two add up to.
           connect_timeout: 3_000,
           receive_timeout: 5_000,
           req_options: req_options()
         ) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 and is_binary(body) and byte_size(body) > 0 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.info("App icon #{url} answered #{status}")
        {:error, :unreachable}

      {:error, reason} ->
        Logger.info("App icon #{url} could not be fetched: #{inspect(reason)}")
        if too_large?(reason), do: {:error, :too_large}, else: {:error, :unreachable}
    end
  end

  # `SafeFetch` halts the stream past `max_bytes` and reports it as prose
  # ("response exceeded N bytes"), not a tagged tuple, so this is a string
  # match on another module's message — which is only safe because a test
  # serves an oversized body end to end and asserts `:too_large` (see
  # `KilnCMS.Branding.AppIconTest`). Reword that message and this goes red
  # rather than silently folding the case back into `:unreachable`, which is
  # the regression it exists to prevent: an operator told to check their DNS
  # about a file their CDN serves perfectly.
  defp too_large?(reason) when is_binary(reason), do: reason =~ "exceeded"
  defp too_large?(_reason), do: false

  # The seam the suite stubs through, matching every other outbound caller
  # (`config :kiln_cms, KilnCMS.Branding.AppIcon, req_options: [plug: …]`). Empty
  # in every other environment, so the real adapter is what production dials.
  defp req_options,
    do: :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

  # A same-origin path is only readable here if it is genuinely a media-library
  # key — `Storage.url/1` is the inverse, and its prefix is configurable
  # (`:base_url`, default `/uploads`), so the prefix is asked for rather than
  # spelled.
  #
  # Anything else same-origin (`/images/brand.png`, a route that renders an
  # image) is NOT a storage key and must not be guessed into one: the previous
  # version passed such a path straight through, `Storage` rejected it as an
  # invalid key, and the operator was told to check that a file their browser
  # loads fine was "publicly reachable" — advice that could never work. It gets
  # its own reason instead.
  #
  # The remaining segment must be a bare key: `Storage.Local` rejects anything
  # containing a separator, so a `..` cannot escape the upload root, and this
  # keeps that true on S3 (where keys are flat) as well.
  defp storage_key(path) do
    stripped = path |> URI.parse() |> Map.get(:path) |> to_string()

    with {:ok, prefix} <- storage_prefix(),
         true <- String.starts_with?(stripped, prefix),
         key = stripped |> String.replace_prefix(prefix, "") |> String.trim_leading("/"),
         true <- key != "" and key == Path.basename(key) do
      {:ok, key}
    else
      _not_a_key -> {:error, :not_in_media_library}
    end
  end

  # The path portion of wherever this deployment serves blobs from. On S3 that
  # is the path of an absolute CDN URL, which is usually "" — so a leading-slash
  # path on an S3 deployment correctly falls through to `:not_in_media_library`
  # unless the CDN is mounted under a path on this origin.
  defp storage_prefix do
    case Storage.url("") do
      "/" <> _rest = prefix -> {:ok, String.trim_trailing(prefix, "/")}
      absolute -> {:ok, absolute |> URI.parse() |> Map.get(:path) |> to_string()}
    end
  rescue
    _error -> :error
  end

  # ── measuring ──────────────────────────────────────────────────────────────

  defp measure({:error, _reason} = error), do: error

  # Removes only the temp file `read/1` just created — see its note on the path.
  # sobelow_skip ["Traversal.FileModule"]
  defp measure({:ok, path}) do
    result =
      case ImageProcessor.validate_upload(path) do
        {:ok, %{content_type: type}} -> check_format(type, path)
        {:error, _reason} -> {:error, :not_an_image}
      end

    File.rm(path)
    result
  end

  # The format is checked against what libvips actually decoded, not against the
  # URL's extension — a CDN happily serves WebP from a `.png` path.
  #
  # PNG and JPEG only, which is NARROWER than the media library accepts, and the
  # reason is iOS: `<link rel="apple-touch-icon">` is the one PWA surface with no
  # format negotiation and no fallback, and iOS silently ignores a WebP or GIF
  # there and substitutes a screenshot of the page — the broken look this whole
  # issue is about, reached through a save the form called successful.
  defp check_format(type, path) when type in @icon_types, do: dimensions(path)
  defp check_format(_type, _path), do: {:error, :not_an_image}

  defp dimensions(path) do
    case Image.open(path) do
      {:ok, image} -> check(Image.width(image), Image.height(image))
      _unreadable -> {:error, :not_an_image}
    end
  rescue
    _error -> {:error, :not_an_image}
  end

  defp check(edge, edge) when edge >= @min_edge, do: {:ok, edge}
  defp check(edge, edge), do: {:error, {:too_small, edge}}
  defp check(width, height), do: {:error, {:not_square, width, height}}
end
