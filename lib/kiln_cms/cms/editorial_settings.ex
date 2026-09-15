defmodule KilnCMS.CMS.EditorialSettings do
  @moduledoc """
  "May an editor publish on this site?" — the read side of
  `KilnCMS.CMS.SiteEditorialSettings.editors_can_publish` — and the one writer
  of that row.

  ## No row, and a failed read, both mean "no"

  A site that never answered keeps the rule every install had before this
  switch existed: publishing is an admin step and editors submit for review.
  Upgrading must not widen who can put content in front of visitors, so the
  column defaults to `false`, and `/setup` is where a new site is asked.

  A read failure answers `false` too. This axis *grants* a permission, so it
  fails closed: the worst a database blip can do is tell an editor to submit
  for review for one request — never publish unreviewed on a site that asked
  for review. (`KilnCMS.CMS.TaskSettings` fails the other way, and says why.)

  ## Uncached, on purpose

  `KilnCMS.CMS.Checks.EditorMayPublish` asks this from inside the publish
  transaction, where a `KilnCMS.Cache.fetch/3` miss would run its fallback on a
  courier process that checks out a second pool connection while the first is
  still held. A publish is rare and already writing, so one indexed single-row
  read is nothing; the UI's reads are once per mount.
  """
  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteEditorialSettings
  alias KilnCMS.CMS.TaskSettings

  @doc "Whether editors may publish on `org` (an org id or `%Organization{}`)."
  @spec editors_can_publish?(Ash.UUID.t() | struct() | nil) :: boolean()
  def editors_can_publish?(nil), do: false

  def editors_can_publish?(org) do
    SiteEditorialSettings
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: org)
    |> case do
      {:ok, %SiteEditorialSettings{editors_can_publish: value}} ->
        value

      {:ok, nil} ->
        false

      {:error, reason} ->
        Logger.warning(
          "editorial settings: could not read editors_can_publish for " <>
            "#{inspect(org_id(org))}, answering no (admins publish): #{inspect(reason)}"
        )

        false
    end
  end

  @doc """
  Whether anyone has ever answered for `org` — i.e. a settings row exists.

  A separate question from `editors_can_publish?/1`, which folds "no row" into
  `false` so the publish check fails closed. Home asks this one to decide
  whether to put "How do you publish?" to an admin of a site that never saw
  `/setup` (a seeded deploy). A read failure answers `true`: the cost of that
  is one unasked question, where answering `false` would nag on every blip.
  Never use this to decide what an editor may do.
  """
  @spec chosen?(Ash.UUID.t() | struct() | nil) :: boolean()
  def chosen?(nil), do: true

  def chosen?(org) do
    SiteEditorialSettings
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: org)
    |> case do
      {:ok, nil} -> false
      {:ok, %SiteEditorialSettings{}} -> true
      {:error, _reason} -> true
    end
  end

  @doc """
  Save `changes` to the site's editorial settings without resetting the columns
  the caller did not mention.

  `:save` is an upsert and every column has a default, so an omitted column is
  written as its *default* over whatever the site chose (the
  `KilnCMS.CMS.SiteCompliance` moduledoc has the mechanism). This reads the
  current answers and sends them all, so the task-default switch and the
  publishing switch can be saved from different pages. `opts` are the `:save`
  options and must carry `:tenant`.
  """
  @spec save(map(), keyword()) :: {:ok, SiteEditorialSettings.t()} | {:error, term()}
  def save(changes, opts) when is_map(changes) do
    org = Keyword.fetch!(opts, :tenant)

    current = %{
      auto_complete_tasks_on_publish: TaskSettings.site_default(org),
      editors_can_publish: editors_can_publish?(org)
    }

    CMS.save_site_editorial_settings(Map.merge(current, changes), opts)
  end

  defp org_id(%{id: id}), do: id
  defp org_id(org), do: org
end
