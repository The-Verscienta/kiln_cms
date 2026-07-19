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
    <header class="border-b border-base-content/10 px-4 py-4 sm:px-6 lg:px-8">
      <div class="mx-auto flex max-w-6xl items-center justify-between gap-4">
        <a href="/" class="flex items-center gap-3">
          <img src={~p"/images/logo-mark.png"} class="h-8 w-auto" alt="" />
          <span class="text-sm font-semibold tracking-tight">KilnCMS</span>
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

    <div class="min-h-screen bg-base-100 lg:grid lg:grid-cols-[15rem_1fr]">
      <%!-- CSS-only mobile drawer: the peer checkbox drives the sidebar + backdrop
            with no socket round-trip, so the menu works before LiveView connects. --%>
      <input id="kiln-nav-toggle" type="checkbox" class="peer sr-only" aria-hidden="true" />
      <label
        for="kiln-nav-toggle"
        class="fixed inset-0 z-30 hidden bg-black/40 peer-checked:block lg:hidden"
        aria-hidden="true"
      ></label>

      <aside class={[
        "fixed inset-y-0 left-0 z-40 flex w-60 -translate-x-full flex-col border-r shadow-xl",
        "border-base-content/10 bg-base-100 transition-transform peer-checked:translate-x-0",
        "lg:static lg:z-auto lg:w-auto lg:translate-x-0 lg:bg-base-200/40 lg:shadow-none"
      ]}>
        <div class="flex h-14 items-center gap-2.5 border-b border-base-content/10 px-4">
          <img src={~p"/images/logo-mark.png"} class="h-7 w-auto" alt="" />
          <span class="text-sm font-semibold tracking-tight">KilnCMS</span>
        </div>
        <nav class="flex-1 overflow-y-auto px-2 py-2" aria-label={gettext("Primary")}>
          <.console_nav current_user={@current_user} active={@active} />
        </nav>
        <div class="border-t border-base-content/10 p-2">
          <div class="flex gap-1 px-1 pb-2 text-xs text-base-content/50">
            <a href="/developers#graphql" class="side-link !py-1 !text-xs">
              {gettext("GraphQL")}
            </a>
            <a href="/developers#json-api" class="side-link !py-1 !text-xs">
              {gettext("JSON:API")}
            </a>
          </div>
          <div
            :if={@current_user}
            class="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm"
          >
            <span class="grid size-8 shrink-0 place-items-center rounded-full bg-primary/15 text-xs font-semibold text-primary uppercase">
              {user_initial(@current_user)}
            </span>
            <span class="min-w-0 flex-1 truncate text-base-content/80">{@current_user.email}</span>
            <a
              href={~p"/sign-out"}
              class="rounded-md p-1.5 text-base-content/60 hover:bg-base-200 hover:text-base-content"
              aria-label={gettext("Sign out")}
              title={gettext("Sign out")}
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            </a>
          </div>
        </div>
      </aside>

      <div class="flex min-h-screen flex-col">
        <header class="sticky top-0 z-20 flex min-h-14 flex-wrap items-center gap-x-3 gap-y-2 border-b border-base-content/10 bg-base-100/90 px-4 py-2 backdrop-blur sm:px-6">
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
            <.theme_toggle />
          </div>
        </header>

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

  # First letter of the signed-in user's email, for the account avatar.
  defp user_initial(%{email: email}) when is_binary(email),
    do: String.upcase(String.first(email) || "?")

  defp user_initial(%{email: email}), do: user_initial(%{email: to_string(email)})
  defp user_initial(_), do: "?"

  # The console sidebar navigation: two role-gated groups (author + configure)
  # plus any plugin-contributed items. `active` (an atom like :content) lights
  # the matching link via aria-current, which the `.side-link` style keys off.
  attr :current_user, :map, default: nil
  attr :active, :atom, default: nil

  defp console_nav(assigns) do
    role = assigns.current_user && assigns.current_user.role
    multi_locale? = length(KilnCMS.I18n.locales()) > 1

    author = [
      %{
        key: :overview,
        label: gettext("Overview"),
        path: ~p"/editor/overview",
        icon: "hero-squares-2x2"
      },
      %{key: :content, label: gettext("Content"), path: ~p"/editor", icon: "hero-document-text"},
      %{key: :media, label: gettext("Media"), path: ~p"/media", icon: "hero-photo"},
      %{key: :taxonomy, label: gettext("Taxonomy"), path: ~p"/editor/taxonomy", icon: "hero-tag"},
      %{
        key: :calendar,
        label: gettext("Calendar"),
        path: ~p"/editor/calendar",
        icon: "hero-calendar-days"
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
      }
    ]

    configure =
      if role == :admin do
        [
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
          %{
            key: :forms,
            label: gettext("Forms"),
            path: ~p"/editor/forms",
            icon: "hero-clipboard-document-list"
          },
          %{
            key: :webhooks,
            label: gettext("Webhooks"),
            path: ~p"/editor/webhooks",
            icon: "hero-bolt"
          },
          %{
            key: :automation,
            label: gettext("Automation"),
            path: ~p"/editor/automation",
            icon: "hero-cpu-chip"
          },
          %{key: :mail, label: gettext("Mail"), path: ~p"/editor/mail", icon: "hero-envelope"},
          %{
            key: :newsletter,
            label: gettext("Newsletter"),
            path: ~p"/editor/newsletter",
            icon: "hero-megaphone"
          },
          %{
            key: :governance,
            label: gettext("Governance"),
            path: ~p"/editor/governance",
            icon: "hero-shield-check"
          },
          %{
            key: :team,
            label: gettext("Team"),
            path: ~p"/editor/team",
            icon: "hero-user-group"
          },
          %{key: :trash, label: gettext("Trash"), path: ~p"/editor/trash", icon: "hero-trash"},
          %{
            key: :settings,
            label: gettext("Settings"),
            path: ~p"/editor/settings",
            icon: "hero-cog-6-tooth"
          }
        ]
      else
        [
          %{
            key: :settings,
            label: gettext("Settings"),
            path: ~p"/editor/settings",
            icon: "hero-cog-6-tooth"
          }
        ]
      end

    plugin =
      for item <- Kiln.Plugins.nav_items(), nav_item_visible?(item, assigns.current_user) do
        %{key: nil, label: item.label, path: item.path, icon: "hero-puzzle-piece"}
      end

    assigns =
      assigns
      |> assign(:author, Enum.filter(author, & &1))
      |> assign(:configure, configure)
      |> assign(:plugin, plugin)

    ~H"""
    <.side_link :for={i <- @author} item={i} active={@active} />
    <p class="side-section">{gettext("Configure")}</p>
    <.side_link :for={i <- @configure} item={i} active={@active} />
    <.side_link :for={i <- @plugin} item={i} active={@active} />
    """
  end

  attr :item, :map, required: true
  attr :active, :atom, default: nil

  defp side_link(assigns) do
    ~H"""
    <.link navigate={@item.path} class="side-link" aria-current={@item.key == @active && "page"}>
      <.icon name={@item.icon} class="size-5 shrink-0 opacity-80" />
      <span class="truncate">{@item.label}</span>
    </.link>
    """
  end

  @doc """
  Minimal chrome for the public delivery frontend (published Pages/Posts and the
  blog index). Deliberately free of the authoring nav.
  """
  # Links to the current page in each available locale (`%{locale, href,
  # current}`); rendered as a language switcher when there's more than one.
  attr :locale_links, :list, default: []
  attr :locale, :string, default: nil, doc: "active locale, to keep nav links locale-prefixed"
  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <header class="border-b border-base-content/10 px-4 py-4 sm:px-6 lg:px-8">
      <div class="mx-auto flex max-w-3xl items-center justify-between gap-4">
        <a href="/" class="flex items-center gap-3">
          <img src={~p"/images/logo-mark.png"} class="h-7 w-auto" alt="" />
          <span class="text-sm font-semibold tracking-tight">KilnCMS</span>
        </a>
        <nav class="flex items-center gap-4 text-sm text-base-content/70">
          <a href={KilnCMS.I18n.localized_path(@locale, "/blog")} class="hover:text-base-content">
            {gettext("Blog")}
          </a>
          <a href={KilnCMS.I18n.localized_path(@locale, "/search")} class="hover:text-base-content">
            {gettext("Search")}
          </a>
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

    <main id="main" class="mx-auto max-w-3xl px-4 py-10 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <footer class="mx-auto max-w-3xl px-4 py-10 text-xs text-base-content/70 sm:px-6 lg:px-8">
      {gettext("Powered by KilnCMS.")}
    </footer>
    """
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
  # mobile menu, so they're defined once.
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
      href={~p"/editor"}
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
      :if={@current_user && nav_item_visible?(item, @current_user)}
      href={item.path}
      class={@item}
    >
      {item.label}
    </a>
    <a :if={is_nil(@current_user)} href={~p"/sign-in"} class={@item}>{gettext("Sign in")}</a>
    <a :if={@current_user} href={~p"/sign-out"} class={@item}>{gettext("Sign out")}</a>
    """
  end

  # A plugin nav item is visible when the user meets its declared role
  # (`:editor` admits admins too, mirroring the core links).
  defp nav_item_visible?(%{role: :admin}, user), do: user.role == :admin
  defp nav_item_visible?(%{role: :editor}, user), do: user.role in [:editor, :admin]
  defp nav_item_visible?(_item, _user), do: false

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
