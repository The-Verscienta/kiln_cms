defmodule KilnCMSWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use KilnCMSWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  alias KilnCMS.Branding

  @doc """
  The masked CSRF token for the `<meta>` tag in `root.html.heex`, or `nil` if
  one can't be produced (#681).

  The root layout now also wraps error pages (`render_errors: [root_layout:
  …]`), which can render from a conn that never reached the normal pipeline — a
  raise from an endpoint-level plug ahead of `Plug.Session` hands the error
  renderer the endpoint's *entry* conn. `get_csrf_token/0` happens not to raise
  there today (it mints a token from the process dictionary), but the error
  handler is the one place a second failure is least acceptable, so token
  resolution fails safe rather than trusting that. An error page carries no
  form to protect, so `nil` is a fine answer; on every normal path a session is
  present and this returns the real token, unchanged.
  """
  @spec csrf_token() :: String.t() | nil
  def csrf_token do
    get_csrf_token()
  rescue
    _ -> nil
  end

  @doc """
  Emits the request org's brand colour tokens as an **unlayered** `<style>`
  block, or nothing at all when the site is unbranded (#48).

  Deliberately not an inline `style=` on `<html>`: an inline style outranks the
  `[data-theme="dark"]` selector, so the dark-mode primary would never apply.
  Only a `<style>` block can carry both rules — see
  `KilnCMS.Branding.css_variables/1` for the full cascade reasoning.

  Permitted with no nonce: `style-src` is `'self' 'unsafe-inline'` and carries
  no nonce source (`KilnCMSWeb.Router`).
  """
  attr :brand, KilnCMS.Branding,
    required: true,
    doc: "the resolved brand — see `brand_or_unbranded/1`, which fails closed (#701)"

  def brand_tokens(assigns) do
    assigns = assign(assigns, :css, assigns.brand.css)

    # `{...}` does NOT interpolate inside <style> (a HEEx raw-text element), so
    # this must use <%= %>. `raw/1` is likewise required: escaping would turn the
    # selector into `[data-theme=&quot;dark&quot;]`, and <style> does not decode
    # character references — dark mode would silently break. Safe because every
    # emitted byte is re-derived from parsed colour channels, never passed through.
    ~H"""
    <style :if={@css}>
      <%= Phoenix.HTML.raw(@css) %>
    </style>
    """
  end

  @doc """
  The site's code-injection custom stylesheet (#1318), in a `<style>` element
  this component owns — the CSS-only half of #490's snippet fields.

  `raw/1`, like `brand_tokens/1` above and for the same raw-text-element
  reason; what makes it safe against element breakout is a two-sided contract:
  `KilnCMS.CMS.Validations.CustomCssStaysCss` refuses `</style` at write time
  and the read-time guard in `KilnCMS.CodeInjection` drops it when resolving the row. The
  value is otherwise verbatim on purpose — this field carries code injection's
  trust model (org-admin write, paper trail, delivery-only render), not
  branding's.
  """
  attr :injection, :any,
    default: nil,
    doc: "the resolved `%KilnCMS.CodeInjection{}`, set only by the :delivery pipeline"

  def custom_css(assigns) do
    assigns = assign(assigns, :css, assigns.injection && assigns.injection.custom_css)

    ~H"""
    <style :if={@css} data-custom-css>
      <%= Phoenix.HTML.raw(@css) %>
    </style>
    """
  end

  @doc """
  Inner layout for the AshAuthentication pages, rendering the white-label banner
  the compile-time `Components.Banner` overrides can't express (#48).

  `AshAuthentication.Phoenix.Overrides` values are Spark DSL literals resolved at
  render from a compile-time map, so there is no per-request hook for the logo or
  the site name. The Banner is blanked in `KilnCMSWeb.AuthOverrides` and this
  layout draws it instead — wired in via `layout:` on the auth route macros, with
  `:assign_current_org` added to their `on_mount` (it resolves from the socket
  host and needs no signed-in user).
  """
  # Deliberately NO `attr :current_org` with a default. `attr` compiles a
  # `Map.put_new/3` into the function, so a declared default puts the key on the
  # assigns *before* the body sees them — which would make the absent case below
  # unreachable, and this layout would go on rendering the default org's
  # identity for a join that resolved no org at all (#701).
  # Always present when this runs as a live layout; the default only guards a
  # direct render in a test. Safe to default (unlike `:current_org` above),
  # since there is no absent-vs-nil distinction to preserve here.
  attr :flash, :map, default: %{}
  slot :inner_content

  def auth(assigns) do
    assigns = assign(assigns, :brand, brand_or_unbranded(assigns))

    ~H"""
    <%!-- Sign-in is where an operator forms their belief about which deployment
          they are on, and a scrubbed clone shows production's logo and site name
          here (#469). Telling them after they authenticate is one page too late. --%>
    <div :if={KilnCMS.Environment.label()} class="-mt-4 mb-4 flex justify-center">
      <.environment_banner />
    </div>
    <div class="mb-6 flex w-full justify-center">
      <a href="/" class="flex items-center">
        <img src={@brand.logo_url} class="h-10 w-auto" alt="" referrerpolicy="no-referrer" />
        <span class="ml-3 text-lg font-semibold tracking-tight text-base-content">
          {@brand.site_name}
        </span>
      </a>
    </div>
    <%!-- The library's own live layout renders `Components.Flash`; replacing it
          with this layout (for the white-label banner above) dropped it, so a
          flash set on an auth page was held in the socket and never drawn (#884).
          `Password.ResetForm` / `MagicLink` report success *only* by flashing —
          without this the /reset and magic-link forms gave no feedback at all.
          Kiln's own `flash_group` (as `Layouts.app/1` uses) rather than the
          library's `Components.Flash`, so auth toasts match the rest of the
          console; that is why the `Components.Flash` override is now gone. --%>
    <.flash_group flash={@flash} />
    {@inner_content}
    """
  end

  @doc """
  The brand to render when the caller may not have resolved an organization at
  all (#701).

  `Branding.for_org(nil)` resolves the **default** organization, which is right
  when a caller deliberately asks for the instance-wide identity and wrong when
  it simply never found out. On a tenant host the second case renders another
  site's name and logo — the leak #48 exists to prevent, and the one #680 and
  #558 closed for the token preview and the error pages.

  The two are distinguishable, and the distinction is exactly the bug: a hook
  that ran always *assigns* `:current_org` (`LiveUserAuth.request_org!/1` returns
  an org or raises), so a **missing key** means no hook ran. So an absent key
  renders unbranded, and a present one keeps resolving as before, including the
  legitimate `nil`.

  ## What this does and does not close

  Defence in depth, and never the whole answer for #701. A url-less join matches
  no route, and the LiveView channel takes the layout from the matched route's
  `live_session` too — so such a join falls back to `view.__live__()[:layout]`.
  For the AshAuthentication views that was *their* layout, not this one, so this
  function never ran on that path and could not have saved it.

  What closed #701 was putting those views behind `KilnCMSWeb.LiveRouteGuard`
  instead (`KilnCMSWeb.AuthLive`), so the join is refused before any layout is
  chosen.

  What this holds for is every path that *does* reach these layouts with no
  resolved org — which is none today (`Plugs.SetTenant` always assigns, and every
  `live_session` carries `:assign_current_org`), and that is the point: the next
  one should render stock rather than another tenant.

  Failing closed here rather than in `Branding.for_org/1` is deliberate. That
  function has callers for which `nil` genuinely means "the instance", the mail
  senders and `SignInAlert` among them; making *it* fail closed would turn a
  branded single-org deployment's reset emails and page titles into stock
  "KilnCMS" to fix a leak that only exists where a hook was skipped.
  """
  @spec brand_or_unbranded(map()) :: Branding.t()
  def brand_or_unbranded(assigns) do
    if Map.has_key?(assigns, :current_org) do
      Branding.for_org(assigns[:current_org])
    else
      Branding.defaults()
    end
  end

  @doc """
  The home-screen icon for iOS (`apple-touch-icon`): the site's verified app
  icon, else the stock mark (#629).

  Through `Branding.verified_app_icon/1`, which is also what the manifest's
  icons and shortcuts gate on — so this link and the manifest can never
  disagree about whether the site has a usable icon.

  Two caveats worth knowing, because this surface is less forgiving than the
  manifest. iOS accepts only PNG and JPEG here, which is why
  `KilnCMS.Branding.AppIcon` refuses a WebP or GIF that the media library would
  otherwise allow. And unlike the manifest — which keeps the stock entries
  alongside a brand icon precisely so an icon that 404s after verification
  cannot make the app uninstallable — `apple-touch-icon` is a single href with
  no second candidate. Verification runs at save and again on a nightly
  AshOban sweep (`SiteBranding` `:reverify_app_icon`, #1147): after a couple of
  consecutive failures the measured size is cleared (URL kept), so this link
  falls back to the stock mark instead of a dead brand URL.
  """
  @spec app_icon_href(map()) :: String.t()
  def app_icon_href(assigns) do
    case assigns |> brand_or_unbranded() |> Branding.verified_app_icon() do
      {url, _size} -> url
      nil -> ~p"/images/apple-touch-icon.png"
    end
  end

  @doc """
  The `og:image` for this page: the page's own, else the site's branding image
  (#560).

  Three properties, each of which the issue asks for explicitly:

  **The page-level chain does not move.** Delivery reads `seo_image` alone and
  assigns it as `:og_image`; this only supplies a fallback *beneath* that, so a
  page that sets one is byte-identical to before.

  **The URL is made absolute against the REQUEST'S OWN host**
  (`KilnCMSWeb.Tenant.base_url/1`, #557). That is why this was blocked: the only
  base URL used to be the deployment-global `:public_base_url`, so on a tenant
  subdomain or custom domain the tag would have advertised an image on the wrong
  host — and a wrong absolute URL in a link preview is worse than no tag.

  **It fails closed**, like `brand_or_unbranded/1` and for the same reason: a
  missing `:current_org` key means no hook ran, and answering that with the
  default org's branding would put another tenant's image on this page.
  """
  @spec social_image(map()) :: String.t() | nil
  def social_image(assigns) do
    assigns[:og_image] || brand_social_image(assigns)
  end

  defp brand_social_image(assigns) do
    with true <- Map.has_key?(assigns, :current_org),
         org when not is_nil(org) <- assigns[:current_org],
         image when is_binary(image) and image != "" <- Branding.for_org(org).social_image_url do
      absolute(image, org)
    else
      _ -> nil
    end
  end

  # An operator may paste either a full URL or a site-relative path, and both
  # are reasonable things to type into that field. Only the second needs a base.
  defp absolute("http://" <> _ = url, _org), do: url
  defp absolute("https://" <> _ = url, _org), do: url

  defp absolute(path, org) do
    KilnCMSWeb.Tenant.base_url(org) <> "/" <> String.trim_leading(path, "/")
  end

  @doc "The site name for an org, resolved through the branding fallback chain."
  def brand_name(org), do: Branding.for_org(org).site_name

  @doc "The header logo URL for an org, resolved through the branding fallback chain."
  def brand_logo(org), do: Branding.for_org(org).logo_url

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_user, :map, default: nil, doc: "the signed-in user, if any"

  attr :current_org, :any,
    default: nil,
    doc: "the request's organization (#336), supplying the white-label branding (#48)"

  attr :container_class, :string,
    default: "mx-auto max-w-5xl space-y-4",
    doc: "classes for the main content container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- Hidden target for the ⌘K/Ctrl-K shortcut: clicking a `navigate` link does
          a client-side LiveView navigation (no full reload) when connected, and
          falls back to a normal load otherwise (#139). --%>
    <.link
      navigate={~p"/editor/search"}
      id="cmdk-search-link"
      class="sr-only"
      tabindex="-1"
      aria-hidden="true"
    >
      {gettext("Search")}
    </.link>
    <%!-- The thin shell's own banner (home, developers, auth-adjacent pages):
          an operator forms their belief about which deployment they are on
          wherever they are, not only inside `console`, which renders its own.
          `/editor/api-keys` — minting a key against the wrong deployment is one
          of the more expensive mistakes on the surface (#469) — now renders in
          `console`, so it carries that one. --%>
    <.environment_banner />
    <header class="border-b border-base-content/10 px-4 py-4 sm:px-6 lg:px-8">
      <div class="mx-auto flex max-w-6xl items-center justify-between gap-4">
        <a href="/" class="flex items-center gap-3">
          <img
            src={brand_logo(@current_org)}
            class="h-8 w-auto"
            alt=""
            referrerpolicy="no-referrer"
          />
          <span class="text-sm font-semibold tracking-tight">{brand_name(@current_org)}</span>
        </a>
        <nav class="flex items-center gap-2 sm:gap-3">
          <%!-- Desktop: inline links --%>
          <div class="hidden items-center gap-2 sm:flex sm:gap-3">
            <.nav_links current_user={@current_user} />
            <.locale_switcher />
          </div>

          <.theme_toggle />

          <%!-- Mobile: hamburger disclosure --%>
          <details class="relative sm:hidden">
            <summary class="flex cursor-pointer list-none items-center rounded-lg p-2 text-base-content/80 hover:bg-base-200 [&::-webkit-details-marker]:hidden">
              <.icon name="hero-bars-3" class="size-5" />
              <span class="sr-only">{gettext("Menu")}</span>
            </summary>
            <div class="absolute right-0 z-50 mt-2 flex w-52 flex-col gap-0.5 rounded-lg border border-base-content/10 bg-base-100 p-2 shadow-lg">
              <.nav_links current_user={@current_user} />
              <div class="mt-1 border-t border-base-content/10 px-1 pt-2">
                <.locale_switcher />
              </div>
            </div>
          </details>
        </nav>
      </div>
    </header>

    <main id="main" class="px-4 py-12 sm:px-6 sm:py-16 lg:px-8">
      <div class={@container_class}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The **console** shell — the authoring/admin app frame in the Kiln design
  language: a persistent left sidebar (brand + grouped navigation + account) and
  a sticky top bar (page title + search + actions + theme). This is what makes
  the editor read as an *application* rather than a Phoenix-generated site. Use
  it for every `/editor/*` LiveView; pass `active` to light the current nav item.

  ## Examples

      <Layouts.console flash={@flash} current_user={@current_user}
        page_title={gettext("Content")} active={:content}>
        <:actions><.button variant="primary">New page</.button></:actions>
        ...
      </Layouts.console>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the signed-in user, if any"

  attr :current_org, :map,
    default: nil,
    doc: "the request's org (#419) — the nav's effective-tier is resolved against it"

  attr :page_title, :string, default: nil, doc: "shown in the top bar"

  attr :active, :atom,
    default: nil,
    doc: "which sidebar nav item to mark current (e.g. :content, :media)"

  attr :container_class, :string,
    default: "mx-auto max-w-6xl",
    doc: "classes for the workspace content container"

  slot :actions, doc: "controls rendered at the right of the top bar"
  slot :inner_block, required: true

  def console(assigns) do
    ~H"""
    <%!-- Hidden ⌘K target: a client-side navigation when connected (see app/1). --%>
    <.link
      navigate={~p"/editor/search"}
      id="cmdk-search-link"
      class="sr-only"
      tabindex="-1"
      aria-hidden="true"
    >
      {gettext("Search")}
    </.link>

    <div class="min-h-screen bg-base-100 lg:grid lg:grid-cols-[var(--side-w)_1fr]">
      <%!-- CSS-only mobile drawer: the peer checkbox drives the sidebar + backdrop
            with no socket round-trip, so the menu works before LiveView connects. --%>
      <input id="kiln-nav-toggle" type="checkbox" class="peer sr-only" aria-hidden="true" />
      <label
        for="kiln-nav-toggle"
        class="fixed inset-0 z-30 hidden bg-black/40 peer-checked:block lg:hidden"
        aria-hidden="true"
      ></label>

      <%!-- After Untitled UI's sidebar (docs/design-language.md): a panel a step
            darker than the workspace in dark mode, and on lg+ a collapse to an
            icon rail. The rail state lives on <html data-sidebar> — restored
            before first paint by root.html.heex, flipped by app.js — because
            LiveView never patches <html>, so it outlives every live navigation
            with no server round-trip. --%>
      <aside class={[
        "side-shell fixed inset-y-0 left-0 z-40 flex w-64 -translate-x-full flex-col border-r shadow-xl",
        "border-sidebar-line bg-sidebar transition-transform peer-checked:translate-x-0",
        "lg:sticky lg:bottom-auto lg:z-auto lg:h-screen lg:w-auto lg:translate-x-0 lg:shadow-none"
      ]}>
        <div class="side-head flex h-16 shrink-0 items-center gap-2.5 px-4">
          <img
            src={brand_logo(@current_org)}
            class="side-brand h-7 w-auto"
            alt=""
            referrerpolicy="no-referrer"
          />
          <span class="side-text min-w-0 flex-1 truncate font-semibold tracking-tight">
            {brand_name(@current_org)}
          </span>
          <button
            type="button"
            class="side-icon-btn side-collapse"
            data-sidebar-toggle
            aria-label={gettext("Collapse sidebar")}
            title={gettext("Collapse sidebar")}
          >
            <.icon name="hero-chevron-double-left" class="size-4" />
          </button>
          <button
            type="button"
            class="side-icon-btn side-expand"
            data-sidebar-toggle
            data-side-tip={gettext("Expand sidebar")}
            aria-label={gettext("Expand sidebar")}
          >
            <.icon name="hero-chevron-double-right" class="size-4" />
          </button>
        </div>
        <nav class="side-nav flex-1 overflow-y-auto px-3 pb-3" aria-label={gettext("Primary")}>
          <.console_nav current_user={@current_user} current_org={@current_org} active={@active} />
        </nav>
        <div class="shrink-0 space-y-3 border-t border-sidebar-line px-3 pt-3 pb-4">
          <.sidebar_theme_toggle />
          <.sidebar_account :if={@current_user} current_user={@current_user} />
        </div>
      </aside>

      <div class="flex min-h-screen flex-col">
        <%!-- The strip rides inside the sticky container rather than above it:
              an environment indicator that scrolls away is visible only when
              nothing is at stake. One border, at the bottom of the header, so
              the shell keeps its single hairline. --%>
        <div class="sticky top-0 z-20">
          <.environment_banner />
          <header class="flex min-h-14 flex-wrap items-center gap-x-3 gap-y-2 border-b border-base-content/10 bg-base-100/90 px-4 py-2 backdrop-blur sm:px-6">
            <label
              for="kiln-nav-toggle"
              class="-ml-1 cursor-pointer rounded-md p-2 text-base-content/70 hover:bg-base-200 lg:hidden"
            >
              <.icon name="hero-bars-3" class="size-5" />
              <span class="sr-only">{gettext("Menu")}</span>
            </label>
            <%!-- Chrome label, not a heading: each page body owns the single <h1>
                (its main heading), so this stays a plain element to preserve
                one-h1-per-page (regression #174). --%>
            <div :if={@page_title} class="truncate text-sm font-semibold tracking-tight">
              {@page_title}
            </div>
            <div class="ml-auto flex min-w-0 flex-wrap items-center justify-end gap-2">
              <.link
                navigate={~p"/editor/search"}
                class="hidden items-center gap-2 rounded-md border border-base-content/15 px-2.5 py-1.5 text-sm text-base-content/60 hover:bg-base-200 sm:flex"
              >
                <.icon name="hero-magnifying-glass" class="size-4" />
                <span>{gettext("Search")}</span>
                <span class="kbd ml-1">⌘K</span>
              </.link>
              {render_slot(@actions)}
              <.locale_switcher />
            </div>
          </header>
        </div>

        <main id="main" class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div class={@container_class}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Names the deployment when `KILN_ENV_LABEL` is set, and renders nothing at all
  otherwise (#469).

  A full-width strip rather than a badge in the header row, deliberately: the
  incident it prevents is an editor working in the wrong environment on a
  scrubbed staging clone whose console is byte-for-byte identical to
  production's, and a pill among six other header controls is exactly the kind
  of thing you stop seeing after a day. In the console it sits *inside* the
  sticky header container for the same reason — a strip that scrolls away is
  visible only at the top of an unscrolled page, which is the moment nothing is
  at stake.

  The label is real text, not colour alone — the colour is the glance, the word
  is what survives a screen reader, a monochrome display and the ~8% of readers
  with a colour-vision deficiency. It carries an `aria-label`, because a bare
  `<div>` in the chrome belongs to no landmark and would otherwise be reachable
  only by reading the page linearly. `role="status"` is deliberately absent:
  this is standing chrome, not an update, and announcing it on every navigation
  would make it noise.

  `KilnCMS.Environment.tone/0` is asked only when there is a label to draw. It
  logs on an unrecognized value and this renders once per page, so asking on a
  deployment that shows no strip would warn forever about a value nothing uses.
  """
  def environment_banner(assigns) do
    assigns = assign(assigns, :label, KilnCMS.Environment.label())

    ~H"""
    <div
      :if={@label}
      aria-label={gettext("Deployment environment")}
      class={
        [
          "flex items-center justify-center gap-2 px-4 py-1 text-xs font-semibold uppercase",
          # The console's own uppercase micro-label tracking (`.side-section` in
          # app.css): loose tracking is load-bearing for legibility in caps, and
          # the shell already picked the value.
          "tracking-[0.06em]",
          environment_tone_class(KilnCMS.Environment.tone())
        ]
      }
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
      <span class="min-w-0 truncate">{gettext("Environment: %{label}", label: @label)}</span>
    </div>
    """
  end

  # `bg-<tone>/N` with `text-<tone>-ink` — an accent used as text on its own pale
  # tint only reaches ~2-4:1 (the ink-token note in assets/css/app.css). Spelled
  # out per tone rather than interpolated: Tailwind scans source for literal
  # class names, so a built string compiles to no CSS at all.
  #
  # No neutral clause: `bg-base-200` is ~1.06:1 against the page it would be
  # drawn on, and a strip nobody can see is worse than no strip.
  defp environment_tone_class("error"), do: "bg-error/20 text-error-ink"
  defp environment_tone_class("info"), do: "bg-info/20 text-info-ink"
  defp environment_tone_class("success"), do: "bg-success/20 text-success-ink"
  defp environment_tone_class(_warning), do: "bg-warning/20 text-warning-ink"

  # First letter of the signed-in user's email, for the account avatar.
  defp user_initial(%{email: email}) when is_binary(email),
    do: String.upcase(String.first(email) || "?")

  defp user_initial(%{email: email}), do: user_initial(%{email: to_string(email)})
  defp user_initial(_), do: "?"

  # The console sidebar navigation: two role-gated groups (author + configure)
  # plus any plugin-contributed items. `active` (an atom like :content) lights
  # the matching link via aria-current, which the `.side-link` style keys off.
  attr :current_user, :map, default: nil
  attr :current_org, :map, default: nil
  attr :active, :atom, default: nil

  defp console_nav(assigns) do
    # Effective capability tier on the CURRENT site (#419) — a global editor
    # demoted (or promoted) by an org membership sees the nav for that tier.
    # Resolve against the passed `current_org` (falling back to the default org
    # only when absent), NOT the default org unconditionally. The fallback is
    # spelled out rather than routed through `Tenant.current_org_id/1`, which
    # now raises on a missing assign (#563): `console/1` declares
    # `attr :current_org, :map, default: nil`, so nil is inside the component's
    # own contract and is the component's to resolve, not the tenant resolver's.
    # The tier only picks which nav links render — every action behind them
    # re-authorizes against the real org — so a default-org tier here is a
    # cosmetic wrong answer, not an access-control one.
    role =
      KilnCMS.Accounts.Scoping.effective_tier(
        assigns[:current_user],
        assigns[:current_org] || KilnCMS.Accounts.default_org_id()
      )

    multi_locale? = length(KilnCMS.I18n.locales()) > 1

    author = [
      %{
        key: :overview,
        label: gettext("Home"),
        path: ~p"/editor/overview",
        icon: "hero-squares-2x2"
      },
      %{key: :content, label: gettext("Content"), path: ~p"/editor", icon: "hero-document-text"},
      %{key: :media, label: gettext("Media"), path: ~p"/media", icon: "hero-photo"},
      %{key: :taxonomy, label: gettext("Taxonomy"), path: ~p"/editor/taxonomy", icon: "hero-tag"},
      %{key: :menus, label: gettext("Menus"), path: ~p"/editor/menus", icon: "hero-bars-3"},
      %{
        key: :calendar,
        label: gettext("Calendar"),
        path: ~p"/editor/calendar",
        icon: "hero-calendar-days"
      },
      %{
        key: :tasks,
        label: gettext("Tasks"),
        path: ~p"/editor/tasks",
        icon: "hero-clipboard-document-check"
      },
      # Content releases (#500) — editorial planning, so it sits with the author
      # group next to the calendar it plots onto, not with the admin tools. The
      # admin-only half (schedule/publish/roll back) is gated on the page.
      %{
        key: :releases,
        label: gettext("Releases"),
        path: ~p"/editor/releases",
        icon: "hero-rocket-launch"
      },
      multi_locale? &&
        %{
          key: :translations,
          label: gettext("Translations"),
          path: ~p"/editor/translations",
          icon: "hero-language"
        },
      %{
        key: :analytics,
        label: gettext("Analytics"),
        path: ~p"/editor/analytics",
        icon: "hero-chart-bar"
      },
      # Outbound broken links (#474). In the author group, not the admin one:
      # fixing a dead citation is editorial work. The opt-in switch on the page
      # is what admins own.
      %{
        key: :links,
        label: gettext("Links"),
        path: ~p"/editor/links",
        icon: "hero-link-slash"
      }
    ]

    # The instance-wide consoles — Team, Billing, System, Mail, Backups, API
    # keys — gate their pages on the GLOBAL role (`LiveUserAuth.platform_admin?/1`,
    # #419/#1160), not on the per-org tier `role` above. A per-org admin passes
    # `role == :admin` and would be shown links those pages only bounce, so the
    # links ask the same predicate the pages do.
    platform_admin? = KilnCMSWeb.LiveUserAuth.platform_admin_user?(assigns[:current_user])

    settings = %{
      key: :settings,
      label: gettext("Settings"),
      path: ~p"/editor/settings",
      icon: "hero-cog-6-tooth"
    }

    configure_groups =
      if role == :admin do
        [
          %{
            label: gettext("Content model"),
            items: [
              %{
                key: :types,
                label: gettext("Content types"),
                path: ~p"/editor/types",
                icon: "hero-cube"
              },
              %{
                key: :fields,
                label: gettext("Fields"),
                path: ~p"/editor/fields",
                icon: "hero-adjustments-horizontal"
              },
              # Next to Content types, not down with Mail: what a feed carries
              # is a statement about content types, and the "has a public
              # index" switch this page defers to lives two items up (#719).
              %{key: :feeds, label: gettext("Feeds"), path: ~p"/editor/feeds", icon: "hero-rss"}
            ]
          },
          %{
            label: gettext("Capture"),
            items: [
              %{
                key: :forms,
                label: gettext("Forms"),
                path: ~p"/editor/forms",
                icon: "hero-clipboard-document-list"
              },
              %{
                key: :funnels,
                label: gettext("Funnels"),
                path: ~p"/editor/funnels",
                icon: "hero-funnel"
              },
              # Content experiments (#982). Beside Funnels: both are "measure
              # what this content does", and an experiment's goal can be a funnel.
              %{
                key: :experiments,
                label: gettext("Experiments"),
                path: ~p"/editor/experiments",
                icon: "hero-beaker"
              },
              # Per-site claim checking (#857). Called "Claim checking" rather
              # than "Compliance", which is already the Governance page's
              # subject and the name of the editor panel this switches on — an
              # admin looking for one should not have to guess which of two
              # items owns it.
              %{
                key: :compliance,
                label: gettext("Claim checking"),
                path: ~p"/editor/compliance",
                icon: "hero-scale"
              }
            ]
          },
          %{
            label: gettext("Delivery"),
            items: [
              %{
                key: :branding,
                label: gettext("Branding"),
                path: ~p"/editor/branding",
                icon: "hero-swatch"
              },
              %{
                key: :code_injection,
                label: gettext("Code injection"),
                path: ~p"/editor/code-injection",
                icon: "hero-code-bracket"
              },
              %{
                key: :redirects,
                label: gettext("Redirects"),
                path: ~p"/editor/redirects",
                icon: "hero-arrow-uturn-right"
              },
              %{key: :slugs, label: gettext("Slugs"), path: ~p"/editor/slugs", icon: "hero-link"},
              %{
                key: :social,
                label: gettext("Social"),
                path: ~p"/editor/social",
                icon: "hero-megaphone"
              }
            ]
          },
          %{
            label: gettext("Ops"),
            items: [
              %{
                key: :webhooks,
                label: gettext("Webhooks"),
                path: ~p"/editor/webhooks",
                icon: "hero-bolt"
              },
              # ActivityPub federation (#967) — beside Webhooks: both are "what
              # this site tells other servers", and both are admin-only.
              %{
                key: :federation,
                label: gettext("Federation"),
                path: ~p"/editor/federation",
                icon: "hero-globe-alt"
              },
              %{
                key: :automation,
                label: gettext("Automation"),
                path: ~p"/editor/automation",
                icon: "hero-cpu-chip"
              },
              %{
                platform: true,
                key: :backups,
                label: gettext("Backups"),
                path: ~p"/editor/backups",
                icon: "hero-archive-box"
              },
              %{
                platform: true,
                key: :mail,
                label: gettext("Mail"),
                path: ~p"/editor/mail",
                icon: "hero-envelope"
              },
              %{
                key: :newsletter,
                label: gettext("Newsletter"),
                path: ~p"/editor/newsletter",
                icon: "hero-megaphone"
              }
            ]
          },
          %{
            label: gettext("Org"),
            items: [
              %{
                platform: true,
                key: :team,
                label: gettext("Team"),
                path: ~p"/editor/team",
                icon: "hero-user-group"
              },
              %{
                key: :governance,
                label: gettext("Governance"),
                path: ~p"/editor/governance",
                icon: "hero-shield-check"
              },
              %{
                platform: true,
                key: :billing,
                label: gettext("Billing"),
                path: ~p"/editor/billing",
                icon: "hero-credit-card"
              },
              %{
                platform: true,
                key: :api_keys,
                label: gettext("API keys"),
                path: ~p"/editor/api-keys",
                icon: "hero-key"
              },
              %{
                key: :trash,
                label: gettext("Trash"),
                path: ~p"/editor/trash",
                icon: "hero-trash"
              },
              %{
                platform: true,
                key: :system,
                label: gettext("System"),
                path: ~p"/editor/system",
                icon: "hero-server-stack"
              },
              settings
            ]
          }
        ]
      else
        [%{label: gettext("Configure"), items: [settings]}]
      end

    # Drop the platform-only items for anyone else, then any group left empty.
    configure_groups =
      configure_groups
      |> Enum.map(fn group ->
        %{group | items: visible_nav_items(group.items, platform_admin?)}
      end)
      |> Enum.reject(&(&1.items == []))

    plugin =
      for item <- Kiln.Plugins.nav_items(), nav_item_visible?(item, role) do
        %{key: nil, label: item.label, path: item.path, icon: "hero-puzzle-piece"}
      end

    assigns =
      assigns
      |> assign(:author, Enum.filter(author, & &1))
      |> assign(:configure_groups, configure_groups)
      |> assign(:plugin, plugin)

    ~H"""
    <.side_link :for={i <- @author} item={i} active={@active} />
    <div :for={group <- @configure_groups}>
      <p class="side-section">{group.label}</p>
      <.side_link :for={i <- group.items} item={i} active={@active} />
    </div>
    <.side_link :for={i <- @plugin} item={i} active={@active} />
    """
  end

  # Items tagged `platform: true` are for platform admins alone (see the
  # comment on `platform_admin?` in `console_nav/1`).
  defp visible_nav_items(items, true = _platform_admin?), do: items
  defp visible_nav_items(items, false), do: Enum.reject(items, &Map.get(&1, :platform, false))

  attr :item, :map, required: true
  attr :active, :atom, default: nil

  defp side_link(assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      class="side-link"
      aria-current={@item.key == @active && "page"}
      data-side-tip={@item.label}
    >
      <.icon name={@item.icon} class="side-icon size-5 shrink-0" />
      <span class="side-text truncate">{@item.label}</span>
    </.link>
    """
  end

  # The sidebar's theme switch: the same `phx:set-theme` dispatch and labels as
  # `theme_toggle/1` (the root layout's inline script does the work), drawn as
  # a segmented System / Light / Dark control. Which segment is lit is decided
  # in app.css from <html data-theme/-source>, not from an assign — the choice
  # lives in localStorage, which the server never sees.
  defp sidebar_theme_toggle(assigns) do
    ~H"""
    <div class="side-theme" role="group" aria-label={gettext("Theme")}>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        data-side-tip={gettext("System")}
        aria-label={gettext("Use system theme")}
      >
        <.icon name="hero-computer-desktop" class="size-4 shrink-0" />
      </button>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        data-side-tip={gettext("Light")}
        aria-label={gettext("Use light theme")}
      >
        <.icon name="hero-sun" class="size-4 shrink-0" />
        <span class="side-text">{gettext("Light")}</span>
      </button>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        data-side-tip={gettext("Dark")}
        aria-label={gettext("Use dark theme")}
      >
        <.icon name="hero-moon" class="size-4 shrink-0" />
        <span class="side-text">{gettext("Dark")}</span>
      </button>
    </div>
    """
  end

  attr :current_user, :map, required: true

  # The account row — avatar, name over email — opening a menu of what used to
  # sit loose in the footer. A <details> so it opens before the socket
  # connects; `ignore_attributes` keeps LiveView's next patch from stripping the
  # client-set `open`, and app.js closes it on an outside click or Escape.
  defp sidebar_account(assigns) do
    assigns = assign(assigns, :name, display_name(assigns.current_user))

    ~H"""
    <details id="side-account" class="side-account" phx-mounted={JS.ignore_attributes(["open"])}>
      <summary class="side-account-row" data-side-tip={@name || @current_user.email}>
        <span class="grid size-9 shrink-0 place-items-center rounded-full bg-primary/15 text-sm font-semibold text-primary-ink uppercase">
          {user_initial(@current_user)}
        </span>
        <span class="side-text min-w-0 flex-1 leading-tight">
          <span :if={@name} class="block truncate text-sm font-semibold">{@name}</span>
          <span class="block truncate text-xs text-base-content/65">{@current_user.email}</span>
        </span>
        <.icon
          name="hero-ellipsis-vertical"
          class="side-text size-5 shrink-0 text-base-content/60"
        />
        <span class="sr-only">{gettext("Account menu")}</span>
      </summary>
      <div class="side-menu">
        <.link navigate={~p"/account"}>
          <.icon name="hero-user-circle" class="size-4 shrink-0" />{gettext("Account")}
        </.link>
        <a href="/developers#graphql">
          <.icon name="hero-code-bracket-square" class="size-4 shrink-0" />{gettext("GraphQL")}
        </a>
        <a href="/developers#json-api">
          <.icon name="hero-code-bracket" class="size-4 shrink-0" />{gettext("JSON:API")}
        </a>
        <hr />
        <a href={~p"/sign-out"}>
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4 shrink-0" />{gettext(
            "Sign out"
          )}
        </a>
      </div>
    </details>
    """
  end

  # The account row's headline: the user's display name, when they set one.
  defp display_name(%{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp display_name(_), do: nil

  @doc """
  Minimal chrome for the public delivery frontend (published Pages/Posts and the
  blog index). Deliberately free of the authoring nav.
  """
  # Links to the current page in each available locale (`%{locale, href,
  # current}`); rendered as a language switcher when there's more than one.
  attr :locale_links, :list, default: []
  attr :locale, :string, default: nil, doc: "active locale, to keep nav links locale-prefixed"

  # Defaults to nil, which resolves the DEFAULT org's branding — so omitting it
  # on a tenant's page shows another site's name and logo. That is #656, and it
  # is why every caller here passes it. The default exists for renders with no
  # request behind them at all (a template rendered directly, a preview of an
  # unresolved tenant), not as a convenience.
  attr :current_org, :any,
    default: nil,
    doc: "the request's organization (#336), supplying the white-label branding (#48)"

  slot :inner_block, required: true

  def public(assigns) do
    brand = Branding.for_org(assigns.current_org)

    assigns =
      assigns
      |> assign(:brand, brand)
      |> assign(
        :header_items,
        brand.header_menu_key |> public_menu_items(assigns) |> Enum.filter(& &1.url)
      )
      |> assign(:footer_items, public_menu_items(brand.footer_menu_key, assigns))

    ~H"""
    <div class="public-shell" data-public-theme={@brand.theme}>
      <%!-- The `public-*` classes are style hooks for the theme presets in
            app.css. They carry no styles of their own. --%>
      <header class="public-header border-b border-base-content/10 px-4 py-4 sm:px-6 lg:px-8">
        <div class="public-measure flex items-center justify-between gap-4">
          <a href="/" class="flex items-center gap-3">
            <img src={@brand.logo_url} class="h-7 w-auto" alt="" referrerpolicy="no-referrer" />
            <span class="public-site-name text-sm font-semibold tracking-tight">
              {@brand.site_name}
            </span>
          </a>
          <nav class="flex flex-wrap items-center gap-4 text-sm text-base-content/70">
            <%!-- A configured header menu replaces the stock links (#1318); top
                  level only — the header has no room for a tree, and the footer
                  menu is the place a deep structure belongs. An empty tree
                  (menu deleted, or missing this locale) falls back to the stock
                  links rather than stripping the site of navigation. --%>
            <%= if @header_items == [] do %>
              <a href={KilnCMS.I18n.localized_path(@locale, "/blog")} class="hover:text-base-content">
                {gettext("Blog")}
              </a>
              <a
                href={KilnCMS.I18n.localized_path(@locale, "/search")}
                class="hover:text-base-content"
              >
                {gettext("Search")}
              </a>
            <% else %>
              <a
                :for={item <- @header_items}
                href={item.url}
                target={item.open_in_new_tab && "_blank"}
                rel={item.open_in_new_tab && "noopener"}
                class="hover:text-base-content"
              >
                {item.label}
              </a>
            <% end %>
            <span
              :if={length(@locale_links) > 1}
              class="flex items-center gap-1"
              aria-label={gettext("Language")}
            >
              <a
                :for={link <- @locale_links}
                href={link.href}
                hreflang={link.locale}
                aria-current={link.current && "true"}
                class={[
                  "inline-flex items-center rounded px-2 py-1.5 uppercase",
                  if(link.current,
                    do: "font-semibold text-base-content",
                    else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
                  )
                ]}
              >
                {link.locale}
              </a>
            </span>
          </nav>
        </div>
      </header>

      <main id="main" class="public-main public-measure px-4 py-10 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <%!-- Footer nav (#1318): the full tree, two levels — top-level items are
            section headings (linked when they have a URL), children are the
            link list beneath. Deeper nesting flattens into its section rather
            than disappearing. --%>
      <nav
        :if={@footer_items != []}
        aria-label={gettext("Footer")}
        class="public-footer-nav border-t border-base-content/10 px-4 py-10 sm:px-6 lg:px-8"
      >
        <div class="public-measure grid grid-cols-2 gap-8 sm:grid-cols-3">
          <div :for={section <- @footer_items} class="space-y-2 text-sm">
            <%= if section.url do %>
              <a href={section.url} class="font-semibold hover:text-base-content">
                {section.label}
              </a>
            <% else %>
              <p class="font-semibold">{section.label}</p>
            <% end %>
            <ul class="space-y-1.5">
              <li :for={item <- flatten_menu_children(section)}>
                <a
                  :if={item.url}
                  href={item.url}
                  target={item.open_in_new_tab && "_blank"}
                  rel={item.open_in_new_tab && "noopener"}
                  class="text-base-content/70 hover:text-base-content"
                >
                  {item.label}
                </a>
              </li>
            </ul>
          </div>
        </div>
      </nav>

      <%!-- Attribution (#48). The stock msgid is kept verbatim for an unbranded
          site — it's asserted by several tests and lives in four catalogs — and a
          white-labelled site gets its own interpolated msgid instead. An org can
          also hide the line entirely. --%>
      <footer
        :if={@brand.show_attribution}
        class="public-attribution public-measure px-4 py-10 text-xs text-base-content/70 sm:px-6 lg:px-8"
      >
        <%= if Branding.branded?(@brand) do %>
          {gettext("Powered by %{name}.", name: @brand.site_name)}
        <% else %>
          {gettext("Powered by KilnCMS.")}
        <% end %>
      </footer>
    </div>
    """
  end

  # The resolved anonymous nav tree for a configured menu key, or `[]` for an
  # unconfigured slot. In the header case only items with a URL survive — a
  # `:none` heading has nothing to click and no children row to explain it
  # there. Locale falls back to the default so the pages rendered without one
  # (the lock screen, in-context editing) still get the site's own nav.
  defp public_menu_items(nil, _assigns), do: []

  defp public_menu_items(key, assigns) do
    locale = assigns[:locale] || KilnCMS.I18n.default_locale()

    KilnCMS.CMS.Menus.public_tree(key, locale, public_org_id(assigns[:current_org]))
  end

  defp public_org_id(%KilnCMS.Accounts.Organization{id: id}), do: id
  defp public_org_id(id) when is_binary(id), do: id
  defp public_org_id(_none), do: KilnCMS.Accounts.default_org_id()

  # Depth beyond the footer's two rendered levels folds into its section in
  # document order — a grandchild link is still reachable, just not indented.
  defp flatten_menu_children(%{children: children}) do
    Enum.flat_map(children, fn child -> [child | flatten_menu_children(child)] end)
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Admin UI language switcher. Each link persists the chosen locale in the
  session (`LocaleController`); LiveViews then restore it via the
  `:restore_locale` on_mount hook. Hidden when only one locale is configured.
  """
  def locale_switcher(assigns) do
    assigns =
      assigns
      |> assign(:locales, KilnCMS.I18n.locales())
      |> assign(:current, Gettext.get_locale(KilnCMSWeb.Gettext))

    ~H"""
    <span
      :if={length(@locales) > 1}
      class="flex items-center gap-1 text-xs"
      aria-label={gettext("Language")}
    >
      <.link
        :for={loc <- @locales}
        href={~p"/locale/#{loc}"}
        aria-current={loc == @current && "true"}
        class={[
          "rounded px-1.5 py-1 uppercase",
          if(loc == @current,
            do: "font-semibold text-base-content",
            else: "text-base-content/60 hover:text-base-content"
          )
        ]}
      >
        {loc}
      </.link>
    </span>
    """
  end

  # Shared authoring-nav links — rendered inline on desktop and stacked in the
  # mobile menu, so they're defined once. Used only by `Layouts.app` (the `/`
  # landing header), which has no site context — so these gate on the global
  # `@current_user.role` (≈ the effective tier on the default org). The
  # per-org-tier nav is `console_nav` on the authoring surface (#419).
  attr :current_user, :map, default: nil

  defp nav_links(assigns) do
    assigns =
      assign(
        assigns,
        :item,
        "rounded-lg px-3 py-1.5 text-sm font-medium text-base-content/80 transition " <>
          "hover:bg-base-200 hover:text-base-content"
      )

    ~H"""
    <a href="/developers#graphql" class={@item}>{gettext("GraphQL")}</a>
    <a href="/developers#json-api" class={@item}>{gettext("JSON:API")}</a>
    <a
      :if={@current_user && @current_user.role in [:editor, :admin]}
      href={~p"/editor/overview"}
      class={@item}
    >
      {gettext("Editor")}
    </a>
    <a
      :if={@current_user && @current_user.role in [:editor, :admin]}
      href={~p"/editor/calendar"}
      class={@item}
    >
      {gettext("Calendar")}
    </a>
    <%!-- Only meaningful with more than one configured locale. --%>
    <a
      :if={
        @current_user && @current_user.role in [:editor, :admin] &&
          length(KilnCMS.I18n.locales()) > 1
      }
      href={~p"/editor/translations"}
      class={@item}
    >
      {gettext("Translations")}
    </a>
    <a
      :if={@current_user && @current_user.role in [:editor, :admin]}
      href={~p"/editor/settings"}
      class={@item}
    >
      {gettext("Settings")}
    </a>
    <a
      :if={@current_user && @current_user.role == :admin}
      href={~p"/editor/fields"}
      class={@item}
    >
      {gettext("Fields")}
    </a>
    <a
      :if={@current_user && @current_user.role == :admin}
      href={~p"/editor/forms"}
      class={@item}
    >
      {gettext("Forms")}
    </a>
    <a
      :if={@current_user && @current_user.role == :admin}
      href={~p"/editor/types"}
      class={@item}
    >
      {gettext("Types")}
    </a>
    <a
      :if={@current_user && @current_user.role == :admin}
      href={~p"/editor/api-keys"}
      class={@item}
    >
      {gettext("API keys")}
    </a>
    <%!-- Plugin-contributed nav (D18), each gated by its declared role. --%>
    <a
      :for={item <- Kiln.Plugins.nav_items()}
      :if={@current_user && nav_item_visible?(item, @current_user.role)}
      href={item.path}
      class={@item}
    >
      {item.label}
    </a>
    <a :if={is_nil(@current_user)} href={~p"/sign-in"} class={@item}>{gettext("Sign in")}</a>
    <a :if={@current_user} href={~p"/sign-out"} class={@item}>{gettext("Sign out")}</a>
    """
  end

  # A plugin nav item is visible when the user's effective tier meets its
  # declared role (`:editor` admits admins too, mirroring the core links);
  # `:viewer`/`:none` see neither.
  defp nav_item_visible?(%{role: :admin}, tier), do: tier == :admin
  defp nav_item_visible?(%{role: :editor}, tier), do: tier in [:editor, :admin]
  defp nav_item_visible?(_item, _tier), do: false

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
      role="group"
      aria-label={gettext("Theme")}
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("Use system theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Use light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Use dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
