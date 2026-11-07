defmodule KilnCMSWeb.AccessDenied do
  @moduledoc """
  Where a console page sends someone who lacks the role it needs (#2143).

  A refusal used to be a flash and a redirect to `/`: the explanation lasted a
  few seconds and the reader landed on a page that had nothing to do with what
  they asked for. Every console guard now redirects to `/access-denied` instead
  (`KilnCMSWeb.PageController.access_denied/2`), a persistent page that names
  the role the page needs, what the viewer's own role can do, and who to ask.

  `path/1` is the single place that builds the URL, so the `needs` values the
  controller whitelists and the ones the guards send cannot drift.

    * `:editor` — an editor or admin on this site.
    * `:admin` — an admin on this site.
    * `:platform` — a platform admin: pages backed by instance-wide resources
      (API keys, accounts, mail, billing, backups, system) that a site admin
      cannot open either.
  """
  use KilnCMSWeb, :verified_routes

  @needs [:editor, :admin, :platform]

  @type needs :: :editor | :admin | :platform

  @doc "The access-denied page for a page that needs `role`."
  @spec path(needs()) :: String.t()
  def path(role) when role in @needs, do: ~p"/access-denied?needs=#{role}"

  @doc """
  Parses the `needs` query value. Anything outside the whitelist (including a
  missing or non-string value) is `nil`, which the page renders as generic copy.
  """
  @spec parse(term()) :: needs() | nil
  def parse("editor"), do: :editor
  def parse("admin"), do: :admin
  def parse("platform"), do: :platform
  def parse(_other), do: nil
end
