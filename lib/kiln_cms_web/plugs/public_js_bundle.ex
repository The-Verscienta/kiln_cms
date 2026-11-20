defmodule KilnCMSWeb.Plugs.PublicJsBundle do
  @moduledoc """
  Opts a controller's HTML pages into `public.js`, the small script for
  signed-out content pages, instead of app.js (#2402). It only sets
  `conn.assigns.js_bundle`; `KilnCMSWeb.Layouts.js_bundle_path/1` makes the
  choice, and still answers app.js for a LiveView, a page with a flash, or a
  build without `public.js`.

  Plugged per controller (`ContentController`, `FormController`,
  `NewsletterController`), never in a router pipeline: the `:delivery` scope
  also serves `MembershipLive` and the plugin LiveViews, and
  `Phoenix.LiveView.Controller.live_render/3` merges the conn's assigns into
  the root layout's. A controller opts in only once its templates are checked
  to need nothing from app.js — no `phx-*` binding, hook, JS command,
  `Layouts.flash_group/1`, or page script that app.js wires up.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: assign(conn, :js_bundle, :public)
end
