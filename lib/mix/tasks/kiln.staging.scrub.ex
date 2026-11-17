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

  ```bash
  DATABASE_URL="postgres://…/kiln_staging" \\
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
end
