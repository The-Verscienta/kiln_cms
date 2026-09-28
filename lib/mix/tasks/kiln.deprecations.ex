defmodule Mix.Tasks.Kiln.Deprecations do
  @shortdoc "Report data only a removed surface read, and migrate legacy audiences"

  @moduledoc """
  Find what this instance still holds that only a surface 0.12 deprecated and
  1.0 removed (#1538, #1543) could read — the data side of
  `KilnCMS.Deprecations`:

    * accounts that read gated content through the removed `User.audiences`
      fallback (they hold audiences but no organization membership);
    * queued webhook and newsletter jobs still in a pre-0.12 argument shape.

  ```
  mix kiln.deprecations                       # report only
  mix kiln.deprecations --migrate-audiences   # give those accounts a membership
  ```

  `--migrate-audiences` gives each listed account a membership on the default
  organization carrying its audiences and standing role — what the fallback
  granted there — and prints the report again. 1.0 also does this on its own
  after every deploy (`KilnCMS.Accounts.LegacyAudiencesWorker`); run it on 0.12
  before upgrading so there is no moment without access.

  Jobs are not migrated: 1.0 cancels each one with a logged error when it runs.
  On 0.12, let the queue drain (or cancel them) before upgrading.

  Exits non-zero while anything is left, so it can gate an upgrade script.

  In a release (no Mix):
  `bin/kiln_cms eval 'KilnCMS.Release.deprecations()'`, or
  `KilnCMS.Release.deprecations(migrate_audiences: true)`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @switches [migrate_audiences: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} = OptionParser.parse!(argv, strict: @switches)

    case KilnCMS.Deprecations.run_and_report(opts, fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
