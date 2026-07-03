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
          <img src={~p"/images/logo.svg"} width="32" alt="" />
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
          <img src={~p"/images/logo.svg"} width="28" alt="" />
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
    <a href="/gql" class={@item}>{gettext("GraphQL")}</a>
    <a href="/api/json" class={@item}>{gettext("JSON:API")}</a>
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
      href={~p"/editor/types"}
      class={@item}
    >
      {gettext("Types")}
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
