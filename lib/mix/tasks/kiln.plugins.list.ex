defmodule Mix.Tasks.Kiln.Plugins.List do
  @shortdoc "List installed Kiln plugins with their catalog metadata"

  @moduledoc """
  Prints every plugin in `config :kiln_cms, :plugins` (decision D18) with its
  declared **catalog metadata** (`version`/`summary`/`homepage`) and its
  contribution surface (domains, blocks, field types, advisories, spam checks,
  nav items, admin/editor/public/plug routes, Oban queues, supervision children).

  This is the local "discovery" half of the vetted-plugin marketplace — the
  data a catalog UI would render, straight from `Kiln.Plugins.manifests/0`
  (see `docs/plugin-extensibility.md`). It never loads or evaluates plugin
  code beyond the compile the build already did; use `mix kiln.plugins.doctor`
  to *verify* the install.

  ## Options

    * `--health` — also check each plugin against hex.pm and the security
      notices feed (`Kiln.Plugins.Health`, #2244) and print its status under
      it. **This makes network requests**: two to hex.pm per Hex plugin (naming
      its package and version) and one or more to the notices feed. Off by
      default, so the plain listing stays offline.

  The flag is the opt-in, so it runs even when the server's own check is
  turned off (`KILN_PLUGIN_HEALTH_CHECK=false`, or `KILN_UPDATE_CHECK=false`
  with the former unset); a note says so. Which feed is asked still follows
  configuration: `KILN_SECURITY_NOTICES_URL=false` (or a fork's update
  settings) keeps the notices leg off here too. The check runs in this Mix
  VM, fresh every time, and leaves the server's cache alone.
  """
  use Mix.Task

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.PluginStatus
  alias Kiln.Plugins.Health.Report

  @requirements ["compile"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [health: :boolean])

    case Kiln.Plugins.manifests() do
      [] ->
        Mix.shell().info("No plugins installed (config :kiln_cms, :plugins is empty).")

      manifests ->
        report = if opts[:health], do: health_report()
        Mix.shell().info("#{length(manifests)} plugin(s) installed:\n")
        Enum.each(manifests, &print(&1, report))
        if report, do: Mix.shell().info("\n" <> report_note(report))
    end

    :ok
  end

  defp print(manifest, nil), do: Mix.shell().info(format(manifest))

  defp print(manifest, report) do
    Mix.shell().info(format(manifest))
    Mix.shell().info(format_health(status_for(report, manifest.module)))
  end

  # Runtime config (the env vars above) and the HTTP client, without booting
  # the application: the check needs neither the database nor the endpoint.
  # `enabled: true` is set for this VM only — passing `--health` is the
  # operator asking for the requests.
  defp health_report do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)

    server_enabled? = Health.enabled?()
    config = Application.get_env(:kiln_cms, Health, [])
    Application.put_env(:kiln_cms, Health, Keyword.put(config, :enabled, true))

    try do
      unless server_enabled? do
        Mix.shell().info(
          "Plugin checks are turned off for the server; checking anyway because --health was passed.\n"
        )
      end

      Health.check(force: true)
    after
      Application.put_env(:kiln_cms, Health, config)
    end
  end

  defp status_for(%Report{plugins: plugins}, module),
    do: Enum.find(plugins, &(&1.plugin == module))

  @doc """
  The `--health` line for one plugin's `Kiln.Plugins.Health.PluginStatus`:
  its overall status, then one indented line per reason. `nil` (no status
  for the module) prints as unknown.
  """
  @spec format_health(PluginStatus.t() | nil) :: String.t()
  def format_health(nil), do: "    health: unknown"

  def format_health(%PluginStatus{} = status) do
    lines = Enum.map(health_reasons(status), &"      - #{&1}")
    Enum.join(["    health: #{overall(status.overall)}" | lines], "\n")
  end

  defp overall(:ok), do: "ok"
  defp overall(:fail), do: "FAIL"
  defp overall(:warn), do: "warning"
  defp overall(:unknown), do: "unknown (not ok: a source did not answer)"
  defp overall(:unverifiable), do: "can't verify (git or path: no registry checksum)"
  defp overall(:not_applicable), do: "built from this project"

  defp health_reasons(status) do
    integrity =
      case status.integrity do
        {:mismatch, %{locked: locked, registry: registry}} ->
          [
            "changed on Hex since this build: locked #{short(locked)}, Hex has #{short(registry)}"
          ]

        :not_found ->
          ["not published on Hex at #{status.version}"]

        _other ->
          []
      end

    notices =
      Enum.map(elem(status.advisories, 1), fn notice ->
        "security notice #{notice.id} (#{notice.severity})" <>
          if(notice.url, do: " #{notice.url}", else: "")
      end)

    integrity ++ notices ++ Enum.map(status.abandonment, &abandonment/1)
  end

  defp abandonment({:retired, reason, _message}), do: "retired on Hex (#{reason})"

  defp abandonment({:stale, at}),
    do: "no release on Hex since #{Calendar.strftime(at, "%Y-%m-%d")}"

  defp abandonment({:sdk_unsupported, requirement, bundled}),
    do: "needs kiln_plugin #{requirement}; this Kiln bundles #{bundled}"

  defp abandonment({:sdk_requirement_invalid, requirement}),
    do: "kiln_plugin requirement can't be read: #{requirement}"

  defp short(checksum) when is_binary(checksum), do: String.slice(checksum, 0, 12)
  defp short(_checksum), do: "?"

  defp report_note(%Report{state: :nothing_to_check}),
    do: "No plugin comes from Hex, git or a path, so nothing was asked."

  defp report_note(%Report{state: :partial}),
    do:
      "Hex or the security notices feed could not be reached; plugins it concerns are unknown, not ok."

  defp report_note(%Report{notices: :disabled}),
    do: "Checked against hex.pm. The security notices feed is turned off."

  defp report_note(%Report{}), do: "Checked against hex.pm and the security notices feed."

  @doc """
  The catalog line for one `t:Kiln.Plugins.manifest/0` — the plugin's name and
  metadata, then everything it contributes.
  """
  @spec format(Kiln.Plugins.manifest()) :: String.t()
  def format(m) do
    header = "* #{m.name}#{version(m.version)} — #{inspect(m.module)}"

    lines =
      [
        m.summary && "    #{m.summary}",
        m.homepage && "    #{m.homepage}",
        "    contributes: #{contributions(m)}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([header | lines], "\n")
  end

  defp version(nil), do: ""
  defp version(v), do: " v#{v}"

  # Only mention what the plugin actually contributes, so the line reads clean
  # for a metadata-only plugin.
  defp contributions(m) do
    parts =
      [
        count("domain", length(m.domains)),
        count("block", length(m.blocks)),
        count("field type", length(m.field_types)),
        count("advisory", length(m.advisories)),
        count("spam check", length(m.spam_checks)),
        count("image backend", length(m.image_backends)),
        count("challenge provider", length(m.challenge_providers)),
        count("security check", length(m.security_checks)),
        count("nav item", m.nav_items),
        count("admin route", m.admin_routes),
        # Every route kind is its own seam (admin-gated, editor-gated, public);
        # a plugin whose only surface is a public booking page contributes just
        # as visibly as one with an admin panel.
        count("editor route", m.editor_routes),
        count("public route", m.public_routes),
        count("plug route", m.plug_routes),
        count("Oban queue", length(m.oban_queues)),
        count("child", m.children)
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "nothing (metadata only)"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp count(_label, 0), do: nil
  defp count(label, 1), do: "1 #{label}"
  defp count("child", n), do: "#{n} children"
  defp count("advisory", n), do: "#{n} advisories"
  defp count(label, n), do: "#{n} #{label}s"
end
