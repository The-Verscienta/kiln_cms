defmodule ShowcaseWeb.Router do
  use ShowcaseWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ShowcaseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ShowcaseWeb.Plugs.Locale
  end

  scope "/", ShowcaseWeb do
    pipe_through :browser

    live "/", BlogLive, :index
    live "/search", SearchLive, :index
    live "/contact", ContactLive, :index
    live "/blog/:slug", PostLive, :show
    # Generic page/any-type document viewer: /doc/page/about, /doc/post/hello.
    live "/doc/:type/:slug", PostLive, :document

    # Switch the active content locale (persisted in the session).
    get "/locale/:locale", LocaleController, :update
  end
end
