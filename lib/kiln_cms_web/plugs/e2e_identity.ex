defmodule KilnCMSWeb.Plugs.E2EIdentity do
  @moduledoc """
  Answers "which checkout is this server actually running?" for the browser
  E2E harness (#1353).

  `e2e/playwright.config.js` reuses an already-listening server locally
  (`reuseExistingServer`), and every checkout defaults to the same port — so
  an orphaned server from a *sibling worktree* answers the health check and
  the whole suite then runs someone else's code against someone else's
  database, failing at sign-in with nothing naming the cause. The fixtures'
  identity check (see `e2e/tests/fixtures.js`) fetches this endpoint once per
  worker and refuses a mismatched root before a single spec runs.

  Mounted only inside the router's compile-gated dev-tools scope
  (`dev_routes` / `mailbox_preview`), which `KilnCMS.Application` refuses in
  `:prod` — the same footing as the Swoosh mailbox. It discloses the server's
  working directory and database name, which is exactly the information a
  developer's own `ps`/`lsof` would show.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    identity = %{
      root: File.cwd!(),
      database: KilnCMS.Repo.config()[:database]
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(identity))
    |> halt()
  end
end
