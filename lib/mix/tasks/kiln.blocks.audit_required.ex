defmodule Mix.Tasks.Kiln.Blocks.AuditRequired do
  @shortdoc "Report legacy rows with nil in a now-required block field (read-only)"
  @moduledoc """
  Flags content rows written before #935 that hold `nil` in a block field now
  declared `required: true` — a gap `Kiln.Block.JsonSchema`'s narrowed,
  non-nullable export schema does not know about, because the read path never
  re-validates on load. See `KilnCMS.Blocks.RequiredFieldAudit` for the full
  explanation of why this reports rather than repairs.

      mix kiln.blocks.audit_required [--org <uuid>]

  Read-only: it changes nothing. Every content type is scanned across every
  org by default; pass `--org` to scope to one.

  ## In a release

  There is no Mix in a release image, so call the module directly:

      bin/kiln_cms eval 'KilnCMS.Blocks.RequiredFieldAudit.run() |> IO.inspect()'
  """
  use Mix.Task

  alias KilnCMS.Blocks.RequiredFieldAudit

  @requirements ["app.start"]

  @switches [org: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    run_opts = if opts[:org], do: [org_id: opts[:org]], else: []

    shell = Mix.shell()
    violations = RequiredFieldAudit.run(run_opts)

    case violations do
      [] ->
        shell.info("No legacy rows found with nil in a required block field.")

      violations ->
        for v <- violations, do: shell.info(format(v))
        shell.info("#{length(violations)} violation(s) found.")
    end
  end

  defp format(v) do
    "#{v.type} #{v.record_id} (org #{v.org_id}): #{v.path} — " <>
      "#{v.block_type}.#{v.field} is nil but required"
  end
end
