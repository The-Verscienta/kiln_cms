defmodule KilnCMS.Branding do
  @moduledoc """
  Resolved white-label branding tokens for one site (#48).

  Three layers, most specific first:

    1. the site's `KilnCMS.CMS.SiteBranding` row (per-org, editor-managed),
    2. `config :kiln_cms, :branding` — the instance-wide operator default
       (`SITE_NAME` / `BRAND_LOGO_URL` / `BRAND_PRIMARY_COLOR`, see
       `config/runtime.exs`), which is what a single-tenant install uses,
    3. the stock KilnCMS defaults.

  A `nil` or blank value at any layer falls through, so clearing a field in the
  editor restores the operator default rather than blanking the header.

  ## Performance contract

  `for_org/1` is on the **public delivery hot path** — once per request, per
  layout — and two things about it are load-bearing:

    * It caches the **resolved struct**, never the row. `KilnCMS.Cache.fetch/3`
      deliberately never caches a `nil`, and most sites have no branding row, so
      caching the lookup itself would mean a database hit on every request
      forever — invisible in development, where one row exists.
    * It **never writes**. Lazily creating a missing row on read (the
      `KilnCMS.Mail.ensure_settings!/0` pattern) would turn an anonymous `GET`
      into an `INSERT`.

  The brand colour is solved into a full light/dark token set by
  `KilnCMS.Branding.Color` at resolve time, so the (pure, ~microsecond but
  non-trivial) contrast search also runs once per org per TTL rather than per
  request.
  """
  alias KilnCMS.Accounts
  alias KilnCMS.Branding.Color
  alias KilnCMS.CMS.Validations.BrandTokens

  require Logger

  defstruct site_name: nil,
            logo_url: nil,
            favicon_url: nil,
            app_icon_url: nil,
            app_icon_size: nil,
            social_image_url: nil,
            brand_color: nil,
            show_attribution: true,
            css: nil

  @type t :: %__MODULE__{
          site_name: String.t(),
          logo_url: String.t(),
          favicon_url: String.t(),
          app_icon_url: String.t() | nil,
          app_icon_size: pos_integer() | nil,
          social_image_url: String.t() | nil,
          brand_color: String.t() | nil,
          show_attribution: boolean(),
          css: String.t() | nil
        }

  @default_site_name "KilnCMS"
  @default_logo_url "/images/logo-mark.png"
  @default_favicon_url "/favicon.ico"

  # Matches the host->org resolution TTL in `KilnCMSWeb.Tenant`. The cache is
  # in-BEAM only (D2), so this also bounds staleness on *other* nodes after a
  # save; the writing node is busted precisely by `Changes.BustBranding`.
  @ttl :timer.minutes(5)

  @doc """
  The resolved tokens for an org — an `%Organization{}`, a bare org id, or `nil`
  (the default org).

  Always returns a struct with `site_name`/`logo_url`/`favicon_url` populated;
  `brand_color` and `css` are `nil` when the site is unbranded.
  """
  @spec for_org(Accounts.Organization.t() | Ash.UUID.t() | nil) :: t()
  def for_org(%Accounts.Organization{id: id}), do: for_org(id)
  def for_org(nil), do: for_org(Accounts.default_org_id())

  def for_org(org_id) when is_binary(org_id) do
    # `resolve/1` returns nil only on an infrastructure failure, which the cache
    # then declines to store — so a transient error degrades to the operator
    # defaults for one request rather than for the whole TTL.
    KilnCMS.Cache.fetch(KilnCMS.Cache.branding_key(org_id), @ttl, fn -> resolve(org_id) end) ||
      defaults()
  end

  def for_org(_), do: defaults()

  @doc """
  The site's app icon as `{url, edge}`, or `nil` when there isn't a usable one
  (#629).

  **The single definition of "this icon may be used."** Three surfaces gate on
  it — the manifest's `icons`, the manifest's `shortcuts[].icons`, and the iOS
  `apple-touch-icon` — and they have to agree: a manifest advertising a brand
  icon while the `apple-touch-icon` points at the stock mark is the split-brand
  look this issue is about, and no test of either surface alone would catch it.

  A size is present only when `KilnCMS.Branding.AppIcon` measured the image, so
  `nil` here means "serve the stock icons" for every caller at once.
  """
  @spec verified_app_icon(t()) :: {String.t(), pos_integer()} | nil
  def verified_app_icon(%__MODULE__{app_icon_url: url, app_icon_size: size})
      when is_binary(url) and is_integer(size) and size > 0,
      do: {url, size}

  def verified_app_icon(_unverified), do: nil

  @doc "The instance-wide (config + stock) tokens, ignoring any per-site row."
  @spec defaults() :: t()
  def defaults, do: build(nil)

  @doc """
  Whether this site has any branding of its own, i.e. whether the public footer
  should say "Powered by <name>" instead of the stock attribution.
  """
  @spec branded?(t()) :: boolean()
  def branded?(%__MODULE__{} = brand), do: brand.site_name != @default_site_name

  defp resolve(org_id) do
    case row(org_id) do
      :error -> nil
      row -> build(row)
    end
  end

  defp build(row) do
    color = pick(row && row.brand_color, config(:primary_color), nil)

    %__MODULE__{
      site_name: pick(row && row.site_name, config(:site_name), @default_site_name),
      logo_url: pick(row && row.logo_url, config(:logo_url), @default_logo_url),
      favicon_url: pick(row && row.favicon_url, config(:favicon_url), @default_favicon_url),
      social_image_url: pick(row && row.social_image_url, config(:social_image_url), nil),
      # No config fallback and no default: an app icon is only ever one this
      # deployment has measured (#629). `app_icon_size` is what the manifest
      # gates on, so an unverified URL is the same as no icon at all.
      #
      # Through `present/1` like every other URL: a blank-but-not-null column
      # is `is_binary/1`, so without it a `""` paired with a size would emit
      # `<link rel="apple-touch-icon" href="">` — which resolves to the current
      # document, i.e. the phone tries to use the HTML page as the icon.
      app_icon_url: present(row && row.app_icon_url),
      app_icon_size: row && row.app_icon_size,
      show_attribution: if(row, do: row.show_attribution, else: true),
      brand_color: color,
      css: css_variables(color)
    }
  end

  @doc """
  The `<style>` body overriding the primary theme tokens for a brand colour, or
  `nil` when the site is unbranded (in which case no `<style>` element is
  emitted at all and the stock ember theme applies untouched).

  **Both the `:root` and the `[data-theme="dark"]` rule are emitted, and that is
  the entire mechanism** — not belt-and-braces. These declarations are
  *unlayered*, and unlayered author CSS outranks every `@layer`; `app.css`
  compiles its light tokens into `@layer theme` and its dark override into
  `@layer base`, and the two selectors are both 0-1-0. So a `:root`-only
  override would beat the dark rule and flatten dark mode — exactly the bug that
  an inline `style=` on `<html>` produces, and the reason this is a `<style>`
  block rather than an attribute. Light rule first, dark second: equal
  specificity means source order decides.

  Every value here is re-derived by `KilnCMS.Branding.Color` from parsed colour
  channels, so no user-supplied byte reaches the stylesheet.
  """
  @spec css_variables(String.t() | nil) :: String.t() | nil
  def css_variables(nil), do: nil

  def css_variables(hex) when is_binary(hex) do
    case Color.derive(hex) do
      {:ok, c} ->
        ":root{--color-primary:#{c.light_primary};--color-primary-content:#{c.light_content};" <>
          "--color-primary-ink:#{c.light_ink}}" <>
          ~s([data-theme="dark"]{--color-primary:#{c.dark_primary};) <>
          "--color-primary-content:#{c.dark_content};--color-primary-ink:#{c.dark_ink}}"

      :error ->
        # No fill/ink pair in the search band cleared AA. Ship the stock theme
        # rather than a brand colour with unreadable buttons.
        #
        # This is the identical operator-visible outcome #1089 was filed on —
        # "a value that changes what every page looks like" — and it cannot be
        # caught at config-provider time the way #1089's own grammar check
        # was: whether a hex clears AA depends on the search itself, not on
        # its shape. Reported via `KilnCMS.Config.Report.warn/2` (#1126) so it
        # reaches Sentry too, not just whatever ships container stdout.
        # Called from `for_org/1`'s cache-miss path (5-minute TTL), so this
        # fires at most once per misconfigured org per TTL window, not once
        # per request.
        KilnCMS.Config.Report.warn(
          "branding_contrast",
          "brand colour #{hex} has no accessible token set; using the stock theme",
          %{hex: hex}
        )

        nil
    end
  end

  # nil and "" both mean "not set at this layer".
  defp pick(a, b, c), do: present(a) || present(b) || c

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_), do: nil

  # A system read: the row is world-readable by policy, but the layout renders
  # for anonymous visitors with no actor, and skipping the authorizer keeps the
  # cache-miss path cheap. Tenant-scoped, so strict tenancy is satisfied.
  #
  # Returns the row, `nil` when the site has none, or `:error` on an
  # infrastructure failure (which must NOT be cached).
  defp row(org_id) do
    case KilnCMS.CMS.list_site_branding(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> row
      {:ok, []} -> nil
      _ -> :error
    end
  rescue
    # e.g. the table doesn't exist yet mid-rolling-deploy. Every page renders
    # through here, so degrade to the operator defaults rather than 500ing the
    # whole install.
    error ->
      Logger.warning("branding lookup failed, using defaults: #{Exception.message(error)}")
      :error
  end

  # The brand colour is held to the same grammar wherever it comes from, so an
  # environment variable can't become the injection vector the database column
  # isn't.
  #
  # Since #1089 the BRAND_PRIMARY_COLOR path is checked at boot in
  # `config/runtime.exs`, through `KilnCMS.Config.Env`, so on a prod release a
  # bad value is dropped before it reaches this key AND reaches Sentry rather
  # than only container stdout.
  #
  # This stays a real guard for everything that is not that path: a compiled
  # `config :kiln_cms, :branding` from a project overlay, an
  # `Application.put_env/3` at runtime, and dev/test — where the runtime.exs
  # block is inside `if config_env() == :prod` and BRAND_PRIMARY_COLOR is never
  # read at all. So the message must NOT tell the reader the value came from an
  # overlay; in the environments where this can fire, that is the one thing it
  # probably did not.
  defp config(:primary_color) do
    case BrandTokens.normalize_color(configured(:primary_color)) do
      nil ->
        if present(configured(:primary_color)) do
          Logger.warning(
            "configured :branding primary_color is not a hex colour; ignoring it. " <>
              "Source is a `config :kiln_cms, :branding` value — an overlay, a " <>
              "runtime put_env, or dev/test config. On a prod release " <>
              "BRAND_PRIMARY_COLOR itself is validated at boot (#1089)."
          )
        end

        nil

      hex ->
        hex
    end
  end

  # `config :kiln_cms, :site_name` predates this module and is still read by
  # `KilnCMS.Provenance` as the *signing identity* — deliberately instance-wide.
  # Falling back to it here means a deployment that only ever set `SITE_NAME`
  # keeps its branding without changing what history anchors attest to.
  defp config(:site_name),
    do: configured(:site_name) || Application.get_env(:kiln_cms, :site_name)

  defp config(key), do: configured(key)

  defp configured(key), do: :kiln_cms |> Application.get_env(:branding, []) |> Keyword.get(key)
end
