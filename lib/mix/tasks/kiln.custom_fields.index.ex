defmodule Mix.Tasks.Kiln.CustomFields.Index do
  @shortdoc "Report drift between :indexed_custom_fields and the database (read-only)"

  @moduledoc """
  Audits the range/sort indexes behind `custom_filter` / `custom_sort`
  (#2359, ADR 0025):

      mix kiln.custom_fields.index --check

  The names a site lists in `config :kiln_cms, :indexed_custom_fields` become
  expression btrees through `mix ash.codegen`. This task compares them with
  the database and with the field registry, in both directions: a listed name
  whose index is missing or invalid, an `_cf_` index no name asks for any
  more, a name no field definition carries, and a definition whose type an
  index is not declared for. **It writes nothing and runs no DDL**: a drift is
  fixed by editing the config and generating a migration.

  Exits non-zero when it finds drift, so it can gate a deploy.
  """

  use Mix.Task

  alias KilnCMS.CMS.IndexedCustomFields

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: [check: :boolean])

    unless opts[:check] do
      Mix.raise("pass --check (this task only reports; it never changes the database)")
    end

    Mix.Task.run("app.start")

    case IndexedCustomFields.check() do
      [] ->
        Mix.shell().info("Indexed custom fields match the database.")

      problems ->
        for {kind, detail} <- problems do
          Mix.shell().error("#{kind}: #{detail}")
        end

        Mix.raise("#{length(problems)} indexed custom field problem(s)")
    end
  end
end
