defmodule Mix.Tasks.Kiln.Export.Schema do
  @shortdoc "Export the delivery JSON Schema (or .d.ts / Swift / Kotlin types) for blocks and content types"
  @moduledoc """
  JSON Schema / TypeScript / Swift / Kotlin export of the block union and content types (#430).

  Describes the `:json` fired-artifact shape — what
  `GET /api/content/:type/:slug?surface=json` returns — so a typed client has
  something to generate against. See `KilnCMS.SchemaExport`.

      mix kiln.export.schema [--format json|ts|swift|kotlin] [--out PATH] [--type NAME,NAME]
                             [--package com.example.kiln]
                             [--org-id UUID | --all-orgs] [--blocks-only]
                             [--base-url URL] [--pretty]

  Examples:

      mix kiln.export.schema --pretty
      mix kiln.export.schema --out priv/static/schema.json --pretty
      mix kiln.export.schema --format ts --out assets/js/kiln.d.ts
      mix kiln.export.schema --format swift --out Sources/Kiln/Kiln.swift
      mix kiln.export.schema --format kotlin --package com.example.kiln --out app/src/main/java/com/example/kiln/Kiln.kt
      mix kiln.export.schema --type post,page --org-id 018f…
      mix kiln.export.schema --all-orgs --out ./schemas --pretty

  Without `--out` the document goes to **stdout** and the summary to stderr, so
  the task pipes into `jq` or a file redirect. `--all-orgs` requires `--out` and
  writes `<out>/<org_id>.<ext>` per site — dynamic content types and custom
  fields are per-organization, so one document cannot describe a fleet.

  `--blocks-only` skips content types entirely and touches no database, which
  is what a CI job that only wants block types should use.

  ## Swift

  `--format swift` writes one self-contained file of `Codable` models
  (`KilnCMS.SchemaExport.Swift`): a struct per content type, block and
  `:group` row, `Block` and `Document` enums that switch on `_type`/`type`
  and keep an `unknown` case, and a bundled `JSONValue` for open maps. It
  needs only the Swift standard library, so it drops into an app target or a
  Swift package as-is.

  The file describes **one site's** schema at the moment of export, so
  regenerate it whenever a content type, a custom field or a block changes —
  `--org-id` picks the site. An app built against an older file keeps
  decoding: unknown keys are ignored, and a new block type or select-style
  enum value lands in an `unknown` case rather than failing the decode. See
  `docs/native-apps.md`.

  ## Kotlin

  `--format kotlin` writes one file of kotlinx.serialization models
  (`KilnCMS.SchemaExport.Kotlin`): a `@Serializable data class` per content
  type, block and `:group` row, `sealed interface Block` and `Document` with
  bundled serializers that switch on `_type`/`type` and keep an `Unknown`
  member, a `@JvmInline value class` per string enum that decodes any value,
  and a `KilnJson` instance (`ignoreUnknownKeys = true`) to decode with.
  `--package` sets the file's package (default `kiln`); it applies to
  `--format kotlin` only. The same regenerate-per-site advice as Swift holds.
  """
  use Mix.Task

  alias KilnCMS.SchemaExport
  alias KilnCMS.SchemaExport.Kotlin
  alias KilnCMS.SchemaExport.Swift
  alias KilnCMS.SchemaExport.TypeScript

  @requirements ["app.start"]

  @switches [
    format: :string,
    out: :string,
    type: :string,
    org_id: :string,
    all_orgs: :boolean,
    blocks_only: :boolean,
    base_url: :string,
    package: :string,
    pretty: :boolean
  ]

  @aliases [o: :out, f: :format]

  @impl Mix.Task
  def run(args) do
    # `parse!/2`, not `parse/2`: OptionParser only understands hyphenated
    # switches, so a plausible-looking `--all_orgs` parses as *unknown* — and
    # under `parse/2` that is silently dropped, leaving the task to do the
    # default thing while the operator believes it fanned out over every site.
    {opts, _positional} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    format = parse_format(opts[:format])
    check_package!(format, opts[:package])
    export_opts = export_opts(opts)

    if opts[:all_orgs],
      do: run_all_orgs(format, export_opts, opts),
      else: run_one(format, export_opts, opts)
  end

  defp run_one(format, export_opts, opts) do
    {body, summary} = render(format, export_opts, opts)
    emit(body, opts[:out])
    report(summary, opts[:out])
  end

  defp run_all_orgs(format, export_opts, opts) do
    dir =
      opts[:out] ||
        Mix.raise("--all-orgs writes one document per site, so it needs --out <dir>.")

    File.mkdir_p!(dir)

    KilnCMS.Accounts.list_org_ids()
    |> Enum.each(fn org_id ->
      path = Path.join(dir, "#{org_id}.#{extension(format)}")
      {body, summary} = render(format, Keyword.put(export_opts, :org_id, org_id), opts)
      File.write!(path, body)
      report(summary, path)
    end)
  end

  defp render(format, export_opts, opts) do
    document = SchemaExport.json_schema(export_opts)
    kiln = Map.fetch!(document, "x-kiln")

    # The org comes from the caller's own options rather than the document: the
    # exported schema deliberately does not carry the tenant id.
    org = export_opts[:org_id] || "default"

    summary =
      "#{length(kiln["blocks"])} block type(s), " <>
        "#{length(kiln["content_types"])} content type(s), org #{org}"

    {encode(document, format, opts), summary}
  end

  # Public for the golden regenerator, which writes its fixture through the
  # same sorted encoder an export does.
  @doc false
  def encode(document, :ts, _opts), do: TypeScript.emit(document)
  def encode(document, :swift, _opts), do: Swift.emit(document)

  def encode(document, :kotlin, opts),
    do: Kotlin.emit(document, package: opts[:package] || Kotlin.default_package())

  def encode(document, :json, opts) do
    opts = if opts[:pretty], do: [pretty: true], else: []
    Jason.encode!(sorted(document), opts) <> "\n"
  end

  # Erlang map iteration order is only sorted up to 32 keys; past that it is a
  # hash order that reshuffles when the map grows. `$defs` is ~19 blocks plus one
  # per content type, so a site with a dozen types crosses the boundary and
  # adding a single block would rewrite the whole file. A schema written to disk
  # is a build artifact that gets committed and diffed, so it has to be stable —
  # `Jason.OrderedObject` preserves the order we give it.
  defp sorted(%Jason.OrderedObject{} = object), do: object

  defp sorted(map) when is_map(map) and not is_struct(map) do
    %Jason.OrderedObject{
      values:
        map
        |> Enum.sort_by(fn {key, _} -> to_string(key) end)
        |> Enum.map(fn {k, v} -> {k, sorted(v)} end)
    }
  end

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other

  defp export_opts(opts) do
    []
    |> put_unless_nil(:org_id, opts[:org_id])
    |> put_unless_nil(:base_url, opts[:base_url])
    |> put_unless_nil(:types, parse_types(opts[:type]))
    |> then(fn acc ->
      if opts[:blocks_only], do: Keyword.put(acc, :blocks_only, true), else: acc
    end)
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_types(nil), do: nil
  defp parse_types(csv), do: String.split(csv, ",", trim: true)

  defp parse_format(nil), do: :json
  defp parse_format(format) when format in ~w(json), do: :json
  defp parse_format(format) when format in ~w(ts d.ts typescript), do: :ts
  defp parse_format(format) when format in ~w(swift), do: :swift
  defp parse_format(format) when format in ~w(kotlin kt), do: :kotlin

  defp parse_format(other),
    do: Mix.raise("Unknown format #{inspect(other)} (expected json|ts|swift|kotlin).")

  defp check_package!(_format, nil), do: :ok

  defp check_package!(:kotlin, package) do
    unless Kotlin.valid_package?(package),
      do: Mix.raise("--package #{inspect(package)} is not a Kotlin package name.")
  end

  defp check_package!(_format, _package),
    do: Mix.raise("--package applies to --format kotlin only.")

  defp extension(:ts), do: "d.ts"
  defp extension(:swift), do: "swift"
  defp extension(:kotlin), do: "kt"
  defp extension(:json), do: "json"

  defp emit(body, nil), do: IO.write(body)

  defp emit(body, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, body)
  end

  # To stderr, so a stdout export stays parseable — same posture as
  # `mix kiln.analytics.export`.
  defp report(summary, nil), do: IO.puts(:stderr, "Exported #{summary}.")
  defp report(summary, path), do: Mix.shell().info("Exported #{summary} to #{path}")
end
