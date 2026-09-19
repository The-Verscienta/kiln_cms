defmodule Mix.Tasks.Kiln.Vault.Reencrypt do
  @shortdoc "Re-encrypt every vault column from an old SECRET_KEY_BASE to the current one"

  @moduledoc """
  Move database-stored key material (the DKIM key, social credentials, billing
  secrets, the ActivityPub actor key — every `KilnCMS.Keys.Vault.Ciphertext`
  column) from an old `SECRET_KEY_BASE` to the current one (#1487). The step
  that makes rotating `SECRET_KEY_BASE` recoverable; see
  `docs/secrets-rotation.md` for the procedure around it.

      mix kiln.vault.reencrypt [--dry-run] [--old-secret-key-base-env VAR]

  The old secret is read from the environment variable **named** by
  `--old-secret-key-base-env`, never from the command line, so it stays out of
  shell history and `ps`. Without the flag it is `PREVIOUS_SECRET_KEY_BASE` as
  the running config read it — the same value that keeps the vault readable
  during the rotation window. With neither, the task still runs, as a check
  that everything opens under the current secret.

  Idempotent: a value that already opens under the current secret is left
  alone. A value that opens under **no** secret it was given is reported by id
  and never overwritten, and the task then exits non-zero.

  In a release (no Mix): `bin/kiln_cms eval 'KilnCMS.Release.reencrypt_vault()'`,
  with the same options as a keyword list (`dry_run: true`,
  `old_secret_key_base_env: "VAR"`).

  ## Options

    * `--dry-run` — report what would change; write nothing.
    * `--old-secret-key-base-env VAR` — the variable holding the old secret.
  """
  use Mix.Task

  alias KilnCMS.Keys.Reencrypt

  @requirements ["app.start"]

  @switches [dry_run: :boolean, old_secret_key_base_env: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} = OptionParser.parse!(argv, strict: @switches)

    case Reencrypt.run_and_report(opts, fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
