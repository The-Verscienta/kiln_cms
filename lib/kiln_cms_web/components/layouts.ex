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

      <Layouts.app flash={@flash}>
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
    <header class="border-b border-base-content/10 px-4 py-4 sm:px-6 lg:px-8">
      <div class="mx-auto flex max-w-6xl items-center justify-between gap-4">
        <a href="/" class="flex items-center gap-3">
          <img src={~p"/images/logo.svg"} width="32" alt="" />
          <span class="text-sm font-semibold tracking-tight">KilnCMS</span>
        </a>
        <nav class="flex items-center gap-2 sm:gap-3">
          <a
            href="/gql"
            class="rounded-lg px-3 py-1.5 text-sm font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            GraphQL
          </a>
          <a
            href="/api/json"
            class="rounded-lg px-3 py-1.5 text-sm font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            JSON:API
          </a>
          <a
            :if={@current_user && @current_user.role in [:editor, :admin]}
            href={~p"/editor"}
            class="rounded-lg px-3 py-1.5 text-sm font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            {gettext("Editor")}
          </a>
          <.locale_switcher />
          <.theme_toggle />
          <a
            :if={is_nil(@current_user)}
            href={~p"/sign-in"}
            class="rounded-lg bg-base-content px-3 py-1.5 text-sm font-semibold text-base-100 transition hover:opacity-90"
          >
            {gettext("Sign in")}
          </a>
          <a
            :if={@current_user}
            href={~p"/sign-out"}
            class="rounded-lg px-3 py-1.5 text-sm font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            {gettext("Sign out")}
          </a>
        </nav>
      </div>
    </header>

    <main class="px-4 py-12 sm:px-6 sm:py-16 lg:px-8">
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
          <a href="/blog" class="hover:text-base-content">{gettext("Blog")}</a>
          <span
            :if={length(@locale_links) > 1}
            class="flex items-center gap-2"
            aria-label={gettext("Language")}
          >
            <a
              :for={link <- @locale_links}
              href={link.href}
              hreflang={link.locale}
              class={[
                "uppercase",
                if(link.current,
                  do: "font-semibold text-base-content",
                  else: "hover:text-base-content"
                )
              ]}
            >
              {link.locale}
            </a>
          </span>
        </nav>
      </div>
    </header>

    <main class="mx-auto max-w-3xl px-4 py-10 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <footer class="mx-auto max-w-3xl px-4 py-10 text-xs text-base-content/50 sm:px-6 lg:px-8">
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
