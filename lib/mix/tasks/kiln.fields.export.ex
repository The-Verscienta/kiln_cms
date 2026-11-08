defmodule Mix.Tasks.Kiln.Fields.Export do
  @shortdoc "Export custom-field definitions to a versioned JSON document"

  @moduledoc """
  Write the site's custom-field definitions (and its admin-defined types) to
  the document `mix kiln.fields.import` reads (#2288) — config sync between
  environments. See `KilnCMS.CMS.FieldSync` and docs/field-sync.md.

      mix kiln.fields.export --out fields.json
      mix kiln.fields.export > fields.json

  Options:

      --out FILE     write here (default: stdout)
      --actor EMAIL  read as this user, who must be an admin (default: the first admin)
      --org SLUG     export this organization (default: the default org)
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} =
      OptionParser.parse!(argv, strict: [out: :string, actor: :string, org: :string])

    # Progress goes to stderr so `> fields.json` stays a clean document.
    case KilnCMS.CMS.FieldSync.export_file(
           opts[:out],
           Keyword.delete(opts, :out),
           &emit(&1, opts)
         ) do
      {:ok, _doc} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end

  defp emit(text, opts) do
    if opts[:out], do: Mix.shell().info(text), else: IO.puts(document?(text), text)
  end

  # The JSON document goes to stdout; the "Acting as" chatter to stderr.
  defp document?("{" <> _), do: :stdio
  defp document?(_), do: :stderr
end
