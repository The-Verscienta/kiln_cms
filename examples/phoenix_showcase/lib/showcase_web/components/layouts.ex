defmodule ShowcaseWeb.Layouts do
  @moduledoc """
  Root and application layouts for the showcase. Styling is a small hand-written
  stylesheet (`priv/static/assets/app.css`) — no Tailwind build — to keep the
  example easy to read and run.
  """
  use ShowcaseWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{assigns[:page_title] || "KilnCMS · headless showcase"}</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <header class="site-header">
      <nav class="container">
        <a href={~p"/"} class="brand">🔥 Kiln <span>headless showcase</span></a>
        <div class="nav-links">
          <.link navigate={~p"/"}>Blog</.link>
          <.link navigate={~p"/search"}>Search</.link>
          <.link navigate={~p"/contact"}>Contact</.link>
          <.locale_switcher locale={assigns[:locale]} locales={assigns[:locales] || []} />
        </div>
      </nav>
    </header>

    <main class="container">
      <.flash_group flash={@flash} />
      {@inner_content}
    </main>

    <footer class="site-footer container">
      <p>
        A database-free Phoenix/LiveView app rendering content from KilnCMS over HTTP.
        Base URL: <code>{Showcase.Kiln.base_url()}</code>
      </p>
    </footer>
    """
  end

  attr :locale, :string, default: nil
  attr :locales, :list, default: []

  def locale_switcher(assigns) do
    ~H"""
    <span :if={length(@locales) > 1} class="locale-switcher">
      <.link
        :for={loc <- @locales}
        href={~p"/locale/#{loc}?return_to=/"}
        class={["locale", loc == @locale && "active"]}
      >
        {String.upcase(loc)}
      </.link>
    </span>
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="flash flash-info" role="alert">
      {msg}
    </div>
    <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="flash flash-error" role="alert">
      {msg}
    </div>
    """
  end
end
