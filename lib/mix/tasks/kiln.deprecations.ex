defmodule Mix.Tasks.Kiln.Deprecations do
  @shortdoc "Report the data a 1.0 upgrade would strand, and migrate legacy audiences"

  @moduledoc """
  Find what this instance still relies on that 0.12 deprecated and 1.0
  removes (#1538) — the data side of `KilnCMS.Deprecations`:

    * accounts that read gated content through the legacy `User.audiences`
      fallback (they hold audiences but no organization membership);
    * queued webhook and newsletter jobs still in a pre-0.12 argument shape.

  ```
  mix kiln.deprecations                       # report only
  mix kiln.deprecations --migrate-audiences   # give those accounts a membership
  ```

  `--migrate-audiences` gives each listed account a membership on the default
  organization carrying its audiences and standing role — what the fallback
  already grants there — and prints the report again. Jobs are not migrated:
  let the queue drain, or cancel them, before upgrading to 1.0.

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
