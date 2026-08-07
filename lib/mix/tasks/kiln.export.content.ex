defmodule Mix.Tasks.Kiln.Export.Content do
  @shortdoc "Export content to a portable JSON envelope"

  @moduledoc """
  Dump content to the portable JSON envelope `mix kiln.import.content` loads
  (#487).

      mix kiln.export.content --out content.json
      mix kiln.export.content --type post --state published --out posts.json

  Contrast `mix kiln.export.static`, which renders the *site*. This exports the
  content itself — blocks, taxonomy, SEO fields and a media manifest — so it
  can be loaded into another Kiln instance, seeded into staging, or kept as a
  portable copy that does not depend on this database.

  ## Options

      --out FILE         write here (default: stdout)
      --type NAME        export only this type; repeatable
      --state STATE      published | draft | archived; repeatable
                         (default: published and draft)
      --locale LOCALE    restrict to one locale
      --limit N          at most N records per type
      --actor EMAIL      read as this user (default: the first admin)
      --org SLUG         export this organization (default: the default org)

  Reads run under the actor's own policies, so the envelope contains exactly
  what that user could have read through the UI — an export is not a way around
  authorization.
  """

  use Mix.Task

  alias KilnCMS.Portability.CLI
  alias KilnCMS.Portability.Export

  @requirements ["app.start"]

  @switches [
    out: :string,
    type: :keep,
    state: :keep,
    locale: :string,
    limit: :integer,
    actor: :string,
    org: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)

    types =
      case Keyword.get_values(opts, :type) do
        [] -> :all
        list -> list
      end

    export_opts =
      CLI.scope!(opts) ++
        [states: states(opts)] ++
        maybe(:locale, opts[:locale]) ++
        maybe(:limit, opts[:limit])

    case Export.to_json(types, export_opts) do
      {:ok, json} -> emit(json, opts[:out])
      {:error, reason} -> Mix.raise("Export failed: #{inspect(reason)}")
    end
  end

  defp states(opts) do
    case Keyword.get_values(opts, :state) do
      [] -> [:published, :draft]
      list -> Enum.map(list, &String.to_existing_atom/1)
    end
  end

  defp emit(json, nil), do: IO.puts(json)

  # The path is an operator's own `--out` argument.
  # sobelow_skip ["Traversal.FileModule"]
  defp emit(json, path) do
    File.write!(path, json)
    Mix.shell().info("Wrote #{byte_size(json)} bytes to #{path}")
  end

  defp maybe(_key, nil), do: []
  defp maybe(key, value), do: [{key, value}]
end
