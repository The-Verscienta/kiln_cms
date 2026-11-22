defmodule Mix.Tasks.Kiln.Staging.Scrub do
  @shortdoc "Scrub PII + outbound secrets from a staging clone of production data"

  @moduledoc """
  Turn a **clone of production** into a safe-to-share staging environment: it
  anonymizes every account (the GDPR-erasure path), purges the tables that hold
  personal data or outbound secrets (API keys, auth tokens, newsletter
  subscribers, form submissions, federation followers, queued jobs, …),
  de-activates webhook endpoints and other outward-facing integrations, and
  drops the mail settings (with the DKIM private key). Optionally seeds one
  usable admin. See `docs/staging-environments.md` for the full table.

  The application boots with Oban inert (`KilnCMS.Staging.inert_oban_config/1`)
  and the backup heartbeat off, so no job cloned from production runs before
  the scrub deletes it.

  **Destructive by design — only run it against a throwaway clone.** It refuses
  without `--yes` and unless the target database name looks ephemeral.

  It also refuses, before the application starts, when `DATABASE_URL` is set
  but names a different server (host and port) or database from the one the
  repo is configured for (#2977). Only the prod configuration reads `DATABASE_URL`: under any other
  `MIX_ENV` the task would scrub the configured database (your dev database)
  instead of the clone the variable names. Run it with `MIX_ENV=prod`.

  ```bash
  MIX_ENV=prod DATABASE_URL="postgres://…/kiln_staging" \\
    mix kiln.staging.scrub --yes \\
      --admin-email you@example.com --admin-password 'a-strong-password'
  ```

  In a production OTP release (no Mix), use the equivalent
  `KilnCMS.Release.scrub_staging/0` via `bin/kiln_cms eval`, or
  `KilnCMS.Staging.scrub!/1` via `bin/kiln_cms rpc`.

  ## Options

    * `--yes` — confirm you mean this database (required).
    * `--force` — skip the ephemeral-name safety check.
    * `--admin-email` / `--admin-password` — provision one pre-confirmed admin.
      Fall back to `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD`.
  """
  use Mix.Task

  # `app.config`, not `app.start`: the application is started below, once
  # Oban's config has been made inert. Started as configured, its queues and
  # plugins would run the clone's copy of production's jobs (mail, webhooks,
  # federation deliveries) before the scrub could delete them.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} =
      OptionParser.parse!(argv,
        strict: [yes: :boolean, force: :boolean, admin_email: :string, admin_password: :string]
      )

    check_database_url!(System.get_env("DATABASE_URL"), KilnCMS.Repo.config())

    Application.put_env(
      :kiln_cms,
      Oban,
      KilnCMS.Staging.inert_oban_config(Application.fetch_env!(:kiln_cms, Oban))
    )

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      KilnCMS.Staging.inert_backups_config(Application.get_env(:kiln_cms, KilnCMS.Backups, []))
    )

    Mix.Task.run("app.start")

    KilnCMS.Staging.scrub!(
      confirm?: opts[:yes],
      force?: opts[:force],
      admin_email: opts[:admin_email],
      admin_password: opts[:admin_password],
      shell: fn message -> Mix.shell().info(message) end
    )
  end

  @doc false
  # Raises when `DATABASE_URL` names another server or database than the
  # repo's configuration (`repo_config`, `KilnCMS.Repo.config/0`): host, port
  # and database name, with localhost, 127.0.0.1 and ::1 (and no host, a local
  # socket) counted as one. Public for its test.
  @spec check_database_url!(String.t() | nil, keyword()) :: :ok
  def check_database_url!(url, _repo_config) when url in [nil, ""], do: :ok

  def check_database_url!(url, repo_config) do
    named = url_target(url)
    configured = config_target(repo_config)

    if named == configured do
      :ok
    else
      Mix.raise("""
      Refusing to scrub: DATABASE_URL names #{describe(named)}, but this Mix
      environment (#{Mix.env()}) is configured for #{describe(configured)}.

      Only MIX_ENV=prod reads DATABASE_URL, so the scrub would have run against
      the configured database instead of the clone. Re-run with MIX_ENV=prod
      (and the variables a prod boot needs, see docs/staging-environments.md).
      """)
    end
  end

  defp config_target(config) do
    case config[:url] do
      url when is_binary(url) ->
        url_target(url)

      _discrete ->
        {local(config[:hostname]), config[:port] || 5432, to_string(config[:database])}
    end
  end

  # The userinfo is dropped here, so no password reaches the message.
  defp url_target(url) do
    uri = URI.parse(url)
    {local(uri.host), uri.port || 5432, uri.path |> to_string() |> String.trim_leading("/")}
  end

  defp local(host) when host in [nil, "", "localhost", "127.0.0.1", "::1", "[::1]"],
    do: "localhost"

  defp local(host), do: to_string(host)

  defp describe({host, port, database}), do: "#{database}@#{host}:#{port}"
end
