defmodule KilnCMS.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :kiln_cms

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Scrub a staging clone of production into a safe-to-share environment, from a
  release **before serving** (`bin/kiln_cms eval`, which doesn't auto-start the
  repo — so we start it here the same way `migrate/0` does).

  Confirmation and the optional staging admin come from the environment
  (`KILN_STAGING_SCRUB=confirm`, `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD`).
  See `KilnCMS.Staging` and `docs/staging-environments.md`.
  """
  def scrub_staging do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        KilnCMS.Staging.scrub!(shell: &IO.puts/1)
      end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
