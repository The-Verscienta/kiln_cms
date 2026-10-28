defmodule Mix.Tasks.Kiln.Fields.Convert do
  @shortdoc "Move JSON-in-text custom-field values into a :group, or a multiple :select or :string"

  @moduledoc """
  Parses a custom field that holds a JSON string (an array of objects, one
  object, or either encoded twice) and writes the rows to a `:group` field —
  or a JSON array of strings, written as the terms of a multiple `:select`
  field or the items of a multiple `:string` field — see `KilnCMS.CMS.FieldConversion` and docs/field-conversion.md.

      mix kiln.fields.convert herb dosages_json --to dosages                # dry run
      mix kiln.fields.convert herb dosages_json --to dosages --apply
      mix kiln.fields.convert herb dosages_json --to dosages --map dose=amount --map units=unit
      mix kiln.fields.convert herb dosages_json --to dosages --apply --skip-invalid --report out.json
      mix kiln.fields.convert herb western_properties --to properties          # terms + counts
      mix kiln.fields.convert clinic services_text --to services --lines      # one per line

  Options:

      --to FIELD         the target group (it and its sub-fields must exist), a
                         select holding several terms, or a list of phrases
      --org SLUG         the organization (default: the default org)
      --apply            write; without it the run is a dry run
      --skip-invalid     write the valid records even when others are invalid
                         (those keep only their string)
      --overwrite        also rewrite records whose group already has rows
      --map OLD=NEW      rename a key in every row (repeatable; groups only)
      --lines            a list of phrases only: read text that is not JSON as
                         one item per line
      --report PATH      also write the report as JSON
      --batch N          records read per page (default 100)

  A **dry run is the default**, and nothing is written while any record is
  invalid unless `--skip-invalid` is given. The source field is left as it
  is; drop it a release later. Re-running skips records already converted.
  """

  use Mix.Task

  alias KilnCMS.CMS.FieldConversion

  @switches [
    to: :string,
    org: :string,
    apply: :boolean,
    skip_invalid: :boolean,
    overwrite: :boolean,
    lines: :boolean,
    map: :keep,
    report: :string,
    batch: :integer
  ]

  @usage "Usage: mix kiln.fields.convert <content_type> <source_field> --to <group_or_select_field> [--apply]"

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    {type, source} =
      case argv do
        [type, source] -> {type, source}
        _other -> Mix.raise(@usage)
      end

    target = opts[:to] || Mix.raise(@usage)
    renames = renames(Keyword.get_values(opts, :map))

    Mix.Task.run("app.start")

    run_opts =
      [
        dry_run?: opts[:apply] != true,
        skip_invalid?: opts[:skip_invalid] == true,
        overwrite?: opts[:overwrite] == true,
        lines?: opts[:lines] == true,
        renames: renames
      ] ++ Keyword.take(opts, [:batch])

    with {:ok, org_id} <- FieldConversion.org_id(opts[:org]),
         {:ok, report} <- FieldConversion.run(org_id, type, source, target, run_opts) do
      print(report, opts[:report])
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp print(report, path) do
    if report.dry_run?, do: Mix.shell().info("── DRY RUN — nothing was written ──")
    Mix.shell().info(FieldConversion.describe(report))
    if path, do: File.write!(path, Jason.encode!(report, pretty: true))

    if report.blocked?,
      do: Mix.raise("#{length(report.problems)} invalid record(s); nothing written")

    unless report.dry_run? or report.problems == [],
      do: Mix.shell().error("#{length(report.problems)} record(s) not converted")
  end

  defp renames(pairs) do
    Map.new(pairs, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [old, new] when old != "" and new != "" -> {old, new}
        _other -> Mix.raise("--map takes OLD=NEW, got #{inspect(pair)}")
      end
    end)
  end
end
