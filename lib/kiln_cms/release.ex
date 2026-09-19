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

  @doc """
  Reset a demo deployment to its golden snapshot from a release **that is not
  serving** (`bin/kiln_cms eval`) — first boot, or with the application stopped.

  Against a running node use `bin/kiln_cms rpc 'KilnCMS.Demo.reset!()'` instead:
  only a reset inside the serving node can close its open documents, evict its
  sockets and flush its caches. Same guards either way. See `KilnCMS.Demo` and
  `docs/demo-mode.md`.
  """
  def reset_demo do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        KilnCMS.Demo.reset!(live?: false, shell: &IO.puts/1)
      end)
  end

  @doc """
  Re-encrypt every vault column from an old `SECRET_KEY_BASE` to the current
  one (#1487) — `mix kiln.vault.reencrypt` for a release, which has no Mix:

      bin/kiln_cms eval 'KilnCMS.Release.reencrypt_vault(dry_run: true)'
      bin/kiln_cms eval 'KilnCMS.Release.reencrypt_vault()'

  Options are the task's: `dry_run: true`, and `old_secret_key_base_env: "VAR"`
  to name the variable holding the old secret (default: the
  `PREVIOUS_SECRET_KEY_BASE` the config read). Works against a running node
  through `bin/kiln_cms rpc` too. Returns `:ok`, or `{:error, message}` when a
  value opened under no secret given; see `KilnCMS.Keys.Reencrypt` and
  `docs/secrets-rotation.md`.
  """
  @spec reencrypt_vault(keyword()) :: :ok | {:error, String.t()}
  def reencrypt_vault(opts \\ []) do
    load_app()
    # `eval` starts no applications, and the vault's derived-key cache is an
    # ETS table `:plug_crypto` owns.
    {:ok, _} = Application.ensure_all_started(:plug_crypto)

    {:ok, result, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        KilnCMS.Keys.Reencrypt.run_and_report(opts, &IO.puts/1)
      end)

    with {:error, message} <- result, do: IO.puts(message)
    result
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
