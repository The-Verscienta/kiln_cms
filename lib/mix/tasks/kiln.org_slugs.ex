defmodule Mix.Tasks.Kiln.OrgSlugs do
  @shortdoc "Find organizations whose slug can't be a hostname, and downcase the ones it can"

  @moduledoc """
  List the organizations whose stored slug can't be a hostname (#1710) — the
  data side of `KilnCMS.Accounts.OrgSlug`, the rule every new slug now passes.

  ```
  mix kiln.org_slugs          # report only
  mix kiln.org_slugs --fix    # downcase the ones where that is enough
  ```

  `--fix` downcases each slug that downcasing alone makes a valid, unreserved
  label clashing with no other org's, logs each rename, and prints the report
  again. Such a subdomain was never reachable (tenant resolution downcases the
  host), so nothing that worked stops working. Every other row is listed for
  the operator to give a new slug. See `KilnCMS.Accounts.OrgSlugAudit`.

  Exits non-zero while anything is left, so it can gate an upgrade script.

  In a release (no Mix): `bin/kiln_cms eval 'KilnCMS.Release.org_slugs()'`, or
  `KilnCMS.Release.org_slugs(fix: true)`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @switches [fix: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} = OptionParser.parse!(argv, strict: @switches)

    case KilnCMS.Accounts.OrgSlugAudit.run_and_report(opts, fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
