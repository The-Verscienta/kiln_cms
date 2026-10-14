defmodule Kiln.ImageBackend do
  @moduledoc """
  The contract for an **image backend** (#1955): an external service that
  stores raster images and renders their sizes and formats itself —
  Cloudflare Images, imgix, Bunny Optimizer, Cloudinary.

  A backend is not a replacement for `KilnCMS.Storage`. It sits beside it and
  takes only what it `accepts?/1`. Everything else — video, audio, documents,
  gated items, an image the backend turns down — goes to the operator's store
  exactly as it would without one. Images can never be gated
  (`KilnCMS.CMS.Changes.MigrateMediaStorage`), so a backend has no private
  storage to provide.

  A plugin contributes one from its entry module, and the operator picks it:

      @impl Kiln.Plugin
      def image_backends, do: [MyPlugin.ImageBackend]

      # config/runtime.exs
      config :kiln_cms, :image_backend, MyPlugin.ImageBackend

  ## Keys

  Kiln chooses the key, as it does for every store: `store/2` is handed the
  key and must keep the image under it (Cloudflare Images calls this a custom
  ID). That is what lets every existing caller — rotate, download, purge —
  reach a backend item through `KilnCMS.Storage` without knowing it is one.

  ## Which items it holds

  `KilnCMS.Media.Ingest` asks the active backend about each new image upload
  bound for the operator's store, after its metadata has been stripped. When
  it accepts, the item records the backend's `name/0` in
  `MediaItem.image_backend`, and from then on every read, write and delete of
  that item's file goes to the backend that name resolves to — never to
  whichever backend is configured today. A site that brought its own bucket
  (#1559) keeps its images there: the backend is an operator choice.

  ## Sizes and formats

  `render_url/2` is the point of a backend. When it answers `{:ok, url}`:

    * `KilnCMS.Media.VariantWorker` records the responsive variants as those
      URLs instead of encoding and storing each one, keeping the `variants`
      map's public shape — headless clients and both SDKs see no difference;
    * `/media/:id/t/<ops>` redirects to the backend's URL instead of
      rendering through libvips.

  Answering `:unsupported` keeps Kiln's own pipeline for that request: the
  variants are encoded locally and stored in the backend through `store/2`.

  ## Adopting images it already holds

  A library imported from elsewhere can arrive as rows that only carry a URL
  into the backend — Kiln holds no file for them, so it can't rotate, derive
  or delete them. `key_for_url/1` lets `mix kiln.media.adopt_image_backend`
  recognise those URLs and hand the rows to the backend
  (`KilnCMS.Media.Adoption`).

  ## Checking the account

  `check/0` answers System → Image backend's "can Kiln reach it?" — a
  credential that has lapsed or been revoked shows there rather than as the
  next upload's error. It may say what it found, as label/value pairs the page
  lists (`{"Stored images", "1,204 of 100,000"}`); those are shown as they
  are, so translate them in the plugin if it translates anything. The default
  doesn't check, and the page says so.
  """

  @typedoc """
  One output image, in the terms both the variant pipeline and the transform
  endpoint already plan in:

    * `source` — the original's `{width, height}`;
    * `crop` — a window in source pixels, `{left, top, width, height}`, or
      `nil` for the whole frame;
    * `width`/`height` — the exact output size, never larger than the crop;
    * `format` — the output encoding;
    * `quality` — `1..100` for a lossy format, `nil` for the backend default.
  """
  @type spec :: %{
          source: {pos_integer(), pos_integer()},
          crop: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()} | nil,
          width: pos_integer(),
          height: pos_integer(),
          format: :jpg | :png | :webp | :avif | :gif,
          quality: 1..100 | nil
        }

  @typedoc "What `accepts?/1` is asked about: the stripped file, already sniffed."
  @type candidate :: %{content_type: String.t(), byte_size: non_neg_integer()}

  @doc """
  The stable identifier recorded on each item this backend holds
  (`MediaItem.image_backend`). Rows outlive module names, so this must never
  change once items carry it. At most 64 characters.
  """
  @callback name() :: String.t()

  @doc """
  Whether the backend has what it needs to run — credentials, an account.
  An unconfigured backend is never offered an upload, so a deployment that
  installs the plugin without its settings keeps working on local storage.
  """
  @callback configured?() :: boolean()

  @doc "Whether this image should go to the backend rather than to the operator's store."
  @callback accepts?(candidate()) :: boolean()

  @doc "Keep the file at `path` under `key`. `{:ok, key}` on success."
  @callback store(key :: String.t(), path :: Path.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "The original's bytes — for downloads, rotation, and Kiln-side rendering."
  @callback fetch(key :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Remove the image at `key`. One that is already gone is success."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc "The public URL of the image at `key`, as uploaded."
  @callback url(key :: String.t()) :: String.t()

  @doc "A URL that renders `spec` from the image at `key`, or `:unsupported`."
  @callback render_url(key :: String.t(), spec()) :: {:ok, String.t()} | :unsupported

  @doc """
  The key of the image `url` names in this backend, or `:error` when it names
  none — for adopting rows imported by URL. The default recognises nothing.
  """
  @callback key_for_url(url :: String.t()) :: {:ok, String.t()} | :error

  @doc """
  Whether the service answers with the backend's settings, for an operator
  to see. `{:ok, facts}` when it does — `facts` are label/value pairs to show
  beside it, `[]` for none — and `{:error, reason}` when it doesn't, where
  `reason` is a sentence an operator can act on. Called on demand, never on
  a request path. The default, `:unsupported`, means the backend can't tell.
  """
  @callback check() :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()} | :unsupported

  # Optional, unlike the other defaulted callbacks: it arrived after 1.0, and a
  # backend written with a bare `@behaviour` must not start warning (and, under
  # `--warnings-as-errors`, failing) for a callback it never needed.
  @optional_callbacks check: 0

  @doc """
  Origins the browser must be allowed to load images from (`img-src`), e.g.
  `["https://imagedelivery.net"]`.
  """
  @callback csp_hosts() :: [String.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.ImageBackend

      @impl Kiln.ImageBackend
      def render_url(_key, _spec), do: :unsupported

      @impl Kiln.ImageBackend
      def csp_hosts, do: []

      @impl Kiln.ImageBackend
      def key_for_url(_url), do: :error

      @impl Kiln.ImageBackend
      def check, do: :unsupported

      defoverridable render_url: 2, csp_hosts: 0, key_for_url: 1, check: 0
    end
  end
end
