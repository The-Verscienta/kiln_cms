defmodule Mix.Tasks.Kiln.Export.Static do
  @shortdoc "Export published content to a static HTML site"

  @moduledoc """
  Export all published content to a static HTML site for CDN-only / high-traffic
  delivery.

  Boots the app with the endpoint listening on a local loopback port, crawls
  every public URL in `sitemap.xml` (plus the home page, blog index, sitemap,
  and robots), and writes each response to an output directory as
  `<path>/index.html` (extension-less paths) or the file itself (e.g.
  `sitemap.xml`). The contents of `priv/static` (compiled assets, images) are
  copied alongside so the export is self-contained.

  Build assets first so the HTML's `/assets/...` references resolve:

      mix assets.deploy
      mix kiln.export.static                 # → priv/static_export
      mix kiln.export.static path/to/out     # custom output dir

  Deploy the resulting directory to any static host / object storage — see
  `docs/static-export.md`.

  ## Options

    * `output` (positional) — output directory (default `priv/static_export`).
    * `--port` — loopback port to render on (default 4999).
  """
  use Mix.Task

  @requirements []

  @default_output "priv/static_export"
  @default_port 4999

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [port: :integer])
    output = List.first(args) || @default_output

    base = boot_server!(opts[:port])

    File.mkdir_p!(output)
    copy_static!(output)

    paths = ["/", "/blog", "/sitemap.xml", "/robots.txt"] ++ sitemap_paths(base)
    paths = Enum.uniq(paths)

    {ok, failed} =
      Enum.reduce(paths, {0, 0}, fn path, {ok, failed} ->
        case export_path(base, output, path) do
          :ok -> {ok + 1, failed}
          :error -> {ok, failed + 1}
        end
      end)

    Mix.shell().info(
      "Exported #{ok} page(s) to #{output}#{if failed > 0, do: ", #{failed} failed", else: ""}."
    )
  end

  # Start the app with the endpoint serving on loopback so we can render pages
  # over HTTP using the real delivery pipeline (cache, SEO, blocks). Asset
  # watchers and the code reloader are disabled — we only need to serve. Returns
  # the base URL at the actually-bound port.
  defp boot_server!(port_override) do
    endpoint = KilnCMSWeb.Endpoint
    config = Application.get_env(:kiln_cms, endpoint, [])
    http = Keyword.get(config, :http, [])
    http = if port_override, do: Keyword.put(http, :port, port_override), else: http

    Application.put_env(
      :kiln_cms,
      endpoint,
      Keyword.merge(config, server: true, watchers: [], code_reloader: false, http: http)
    )

    Mix.Task.run("app.start")

    port =
      case endpoint.config(:http)[:port] do
        p when is_binary(p) -> String.to_integer(p)
        p when is_integer(p) -> p
        _ -> 4000
      end

    "http://127.0.0.1:#{port}"
  end

  # Parse the <loc> entries out of the generated sitemap and reduce each to a
  # local path (the sitemap uses the public_base_url host; we render locally).
  defp sitemap_paths(base) do
    case fetch(base <> "/sitemap.xml") do
      {:ok, body} ->
        Regex.scan(~r|<loc>(.*?)</loc>|, body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&(&1 |> unescape() |> URI.parse() |> path_with_query()))
        |> Enum.reject(&is_nil/1)

      :error ->
        Mix.shell().error("Could not read sitemap.xml; exporting home/blog only.")
        []
    end
  end

  defp path_with_query(%URI{path: nil}), do: nil
  defp path_with_query(%URI{path: path, query: nil}), do: path
  defp path_with_query(%URI{path: path, query: q}), do: "#{path}?#{q}"

  defp export_path(base, output, path) do
    case fetch(base <> path) do
      {:ok, body} ->
        dest = Path.join(output, local_file(path))
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, body)
        :ok

      :error ->
        Mix.shell().error("  failed: #{path}")
        :error
    end
  end

  # Map a request path to a file on disk: a path whose last segment has an
  # extension is written verbatim; everything else becomes `<path>/index.html`.
  defp local_file(path) do
    trimmed = path |> String.split("?") |> hd() |> String.trim_leading("/")

    cond do
      trimmed == "" -> "index.html"
      Path.extname(trimmed) != "" -> trimmed
      true -> Path.join(trimmed, "index.html")
    end
  end

  defp copy_static!(output) do
    static = Application.app_dir(:kiln_cms, "priv/static")

    if File.dir?(static) do
      File.cp_r!(static, output)
      # The digest manifest isn't useful in a static export.
      File.rm(Path.join(output, "cache_manifest.json"))
    end
  end

  defp fetch(url) do
    case Req.get(url, retry: false, redirect: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, to_string(body)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp unescape(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
