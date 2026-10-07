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

  @doc """
  `mix kiln.mail.scrub` for a release (#1843): strip the sign-in links that
  releases before 1.0 left in stored mail job errors and finished mail jobs.

      bin/kiln_cms eval 'KilnCMS.Release.scrub_mail_jobs()'

  The upgrade runs it once already; this is for a backup restored from before
  it. Returns the counts `KilnCMS.Mail.Scrub.run/1` reports.
  """
  @spec scrub_mail_jobs() :: KilnCMS.Mail.Scrub.result()
  def scrub_mail_jobs do
    load_app()

    {:ok, result, _} = Ecto.Migrator.with_repo(hd(repos()), &KilnCMS.Mail.Scrub.run/1)

    IO.puts(
      "Mail jobs scrubbed: #{result.errors_redacted} with errors redacted, " <>
        "#{result.bodies_dropped} finished jobs' messages dropped."
    )

    result
  end

  @doc """
  `mix kiln.links.backfill` for a release (#1594): write the reference edges
  for `:reference` custom field values that have none, and delete the ones no
  stored value implies.

      bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'

  The upgrade to 1.1 runs it once already; this is for a backup restored from
  before it. Returns the counts `KilnCMS.CMS.ContentLinks.Backfill.run/1`
  reports.
  """
  @spec backfill_reference_links() :: KilnCMS.CMS.ContentLinks.Backfill.result()
  def backfill_reference_links do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(hd(repos()), &KilnCMS.CMS.ContentLinks.Backfill.run/1)

    IO.puts("Reference links: #{result.inserted} written, #{result.deleted} removed.")
    result
  end

  @doc """
  `mix kiln.deprecations` for a release (#1538, #1543): report the accounts and
  queued jobs still holding data only a removed surface read, and optionally
  move the accounts onto a membership first.

      bin/kiln_cms eval 'KilnCMS.Release.deprecations()'
      bin/kiln_cms eval 'KilnCMS.Release.deprecations(migrate_audiences: true)'

  Works against a running node through `bin/kiln_cms rpc` too. Returns `:ok`
  when nothing is left, `{:error, message}` otherwise; see
  `KilnCMS.Deprecations`.
  """
  @spec deprecations(keyword()) :: :ok | {:error, String.t()}
  def deprecations(opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        KilnCMS.Deprecations.run_and_report(opts, &IO.puts/1)
      end)

    with {:error, message} <- result, do: IO.puts(message)
    result
  end

  @doc """
  `mix kiln.org_slugs` for a release (#1710): list the organizations whose
  slug can't be a hostname, and optionally downcase the ones where that is
  enough first.

      bin/kiln_cms eval 'KilnCMS.Release.org_slugs()'
      bin/kiln_cms eval 'KilnCMS.Release.org_slugs(fix: true)'

  Returns `:ok` when every slug is a valid host label, `{:error, message}`
  otherwise; see `KilnCMS.Accounts.OrgSlugAudit`.
  """
  @spec org_slugs(keyword()) :: :ok | {:error, String.t()}
  def org_slugs(opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        KilnCMS.Accounts.OrgSlugAudit.run_and_report(opts, &IO.puts/1)
      end)

    with {:error, message} <- result, do: IO.puts(message)
    result
  end

  @doc """
  Rewrite every block tree still stored in a legacy shape to the typed shape
  (#1537) — `mix kiln.blocks.backfill` for a release, which has no Mix:

      bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks(dry_run: true)'
      bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks()'

  Options are the task's: `dry_run: true`, `batch: n`, `tables: ["pages"]`.
  Safe against a live site and resumable; returns `:ok`, or `{:error,
  message}` when a row could not be converted (it is listed, and not
  written). See `KilnCMS.CMS.BlockBackfill`.
  """
  @spec backfill_blocks(keyword()) :: :ok | {:error, String.t()}
  def backfill_blocks(opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        KilnCMS.CMS.BlockBackfill.run_and_report(opts, &IO.puts/1)
      end)

    with {:error, message} <- result, do: IO.puts(message)
    result
  end

  @doc """
  `mix kiln.import.wordpress` for a release (#487): import a WordPress WXR
  export into the **running** node.

      bin/kiln_cms rpc 'KilnCMS.Release.import_wordpress("/data/wordpress.xml", dry_run: true)'
      bin/kiln_cms rpc 'KilnCMS.Release.import_wordpress("/data/wordpress.xml", author_map: %{"jo" => "jo@example.com"})'

  Run it through `rpc`, not `eval`. The import enqueues media jobs, fetches
  images through SafeFetch and busts the content caches, so it needs the
  fully started application; an `eval` node has none of that, and this
  returns an error there instead of half-importing. The path is read on the
  node, so copy the export into the container first.

  Options are the task's flags as a keyword list (`dry_run: true`,
  `actor: "email"`, `org: "slug"`, `limit: 20`, `skip_media: true`,
  `redirects: false`, `on_conflict: :error`, `author_map:`, `drain_media:
  true`, `locale:`); an unknown one is refused, so a misspelt `dry_run:`
  cannot run for real. The report prints in the `rpc` terminal. Returns
  `{:ok, report}` or `{:error, message}`; see
  `KilnCMS.Portability.Commands`.
  """
  @spec import_wordpress(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import_wordpress(path, opts \\ []) do
    run_import(&KilnCMS.Portability.Commands.import_wordpress/3, path, opts)
  end

  @doc """
  `mix kiln.import.ghost` for a release (#1876): import a Ghost JSON export
  into the **running** node.

      bin/kiln_cms rpc 'KilnCMS.Release.import_ghost("/data/ghost.json", site_url: "https://blog.example.com", dry_run: true)'

  `site_url:` is the task's `--site-url`; the other options, and the reason it
  must run through `rpc`, are `import_wordpress/2`'s.
  """
  @spec import_ghost(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import_ghost(path, opts \\ []) do
    run_import(&KilnCMS.Portability.Commands.import_ghost/3, path, opts)
  end

  @doc """
  `mix kiln.import.content` for a release (#487): load a portable JSON
  envelope written by `mix kiln.export.content`, or a CSV file with `type:`,
  into the **running** node.

      bin/kiln_cms rpc 'KilnCMS.Release.import_content("/data/content.json", dry_run: true)'
      bin/kiln_cms rpc 'KilnCMS.Release.import_content("/data/listings.csv", type: "listing")'

  Options, and the reason it must run through `rpc`, are
  `import_wordpress/2`'s, less `author_map:` and plus `type:`.
  """
  @spec import_content(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import_content(path, opts \\ []) do
    run_import(&KilnCMS.Portability.Commands.import_content/3, path, opts)
  end

  # No `load_app`/`with_repo` here: unlike the tasks above, an import cannot
  # run on the bare repo `eval` gives, so it refuses rather than starting a
  # second copy of the application next to the serving one. `serving?` is an
  # argument only so the test can take the `eval` branch.
  @doc false
  def run_import(command, path, opts, serving? \\ serving?()) do
    result =
      if serving? do
        command.(path, opts, &IO.puts/1)
      else
        {:error,
         """
         The import needs the running application (its job queue, media fetching
         and caches), and this node has not started it. Run it against the live
         node with `bin/kiln_cms rpc '...'`, not `bin/kiln_cms eval`.
         """}
      end

    with {:error, message} <- result, do: IO.puts(message)
    result
  end

  defp serving? do
    Enum.any?(Application.started_applications(), &match?({@app, _, _}, &1))
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
