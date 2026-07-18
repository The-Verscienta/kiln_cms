defmodule Mix.Tasks.Kiln.Staging.Scrub do
  @shortdoc "Scrub PII + outbound secrets from a staging clone of production data"

  @moduledoc """
  Turn a **clone of production** into a safe-to-share staging environment: it
  anonymizes every account (the GDPR-erasure path), purges API keys / auth
  tokens / recorded search queries, de-activates webhook endpoints, and drops
  the mail settings (with the DKIM private key). Optionally seeds one usable
  admin. See `docs/staging-environments.md`.

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

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} =
      OptionParser.parse!(argv,
        strict: [yes: :boolean, force: :boolean, admin_email: :string, admin_password: :string]
      )

    KilnCMS.Staging.scrub!(
      confirm?: opts[:yes],
      force?: opts[:force],
      admin_email: opts[:admin_email],
      admin_password: opts[:admin_password],
      shell: fn message -> Mix.shell().info(message) end
    )
  end
end
