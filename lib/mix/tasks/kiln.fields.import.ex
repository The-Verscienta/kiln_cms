defmodule Mix.Tasks.Kiln.Fields.Import do
  @shortdoc "Import custom-field definitions from a kiln.fields.export document"

  @moduledoc """
  Plan, and with `--apply` write, a document made by `mix kiln.fields.export`
  (#2288). A **dry run is the default**: it prints the diff and checks every
  write inside a transaction it rolls back. See `KilnCMS.CMS.FieldSync` and
  docs/field-sync.md.

      mix kiln.fields.import fields.json             # diff + dry run
      mix kiln.fields.import fields.json --apply
      mix kiln.fields.import fields.json --apply --prune

  Options:

      --apply             write (one transaction: all or nothing)
      --prune             also delete fields the file does not list
      --allow-data-loss   proceed with changes that drop values records hold
                          (a delete, a type change, a list made single)
      --actor EMAIL       act as this user, who must be an admin (default: the first admin)
      --org SLUG          import into this organization (default: the default org)
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, args} =
      OptionParser.parse!(argv,
        strict: [
          apply: :boolean,
          prune: :boolean,
          allow_data_loss: :boolean,
          actor: :string,
          org: :string
        ]
      )

    path =
      case args do
        [path] -> path
        _other -> Mix.raise("Usage: mix kiln.fields.import FILE [--apply] [--prune]")
      end

    case KilnCMS.CMS.FieldSync.import_file(path, opts, &Mix.shell().info(&1)) do
      {:ok, _report} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
