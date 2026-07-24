defmodule Mix.Tasks.Kiln.Slugs.Regenerate do
  @shortdoc "Bulk-regenerate content slugs (pathauto's update-all-aliases, #455)"

  @moduledoc """
  Re-derives content slugs through the current rules (per-type patterns, SEO
  keywords, stop words) with the same dedupe the editor uses. Dry run by
  default — prints every old → new rename; `--apply` performs them through
  each type's normal `:update` action, so published renames leave 301
  redirects behind.

      mix kiln.slugs.regenerate                      # dry run, all types
      mix kiln.slugs.regenerate --type post          # one type
      mix kiln.slugs.regenerate --apply              # perform the renames
      mix kiln.slugs.regenerate --include-pinned     # also hand-picked slugs

  Slugs that look hand-picked (they don't match their own derivation) are
  skipped unless `--include-pinned` — required after a convention change,
  where every pre-change slug necessarily looks hand-picked. `--org <uuid>`
  targets a specific site (defaults to the sole org).
  """

  use Mix.Task

  @switches [type: :string, apply: :boolean, include_pinned: :boolean, org: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    kind = opts[:type] || :all
    org_id = opts[:org] || KilnCMS.Accounts.default_org_id()
    regen_opts = [include_pinned: opts[:include_pinned] == true]

    if opts[:apply] do
      summary = KilnCMS.CMS.SlugRegeneration.run(kind, org_id, regen_opts)
      print_changes(summary)

      Mix.shell().info(
        "\nDone: #{summary.changed} renamed, #{summary.pinned_skipped} hand-picked skipped, " <>
          "#{length(summary.failed)} failed, #{summary.scanned} scanned."
      )
    else
      summary = KilnCMS.CMS.SlugRegeneration.preview(kind, org_id, regen_opts)
      print_changes(summary)

      Mix.shell().info(
        "\nDry run: #{length(summary.changes)} would change, " <>
          "#{summary.pinned_skipped} hand-picked skipped, #{summary.scanned} scanned. " <>
          "Re-run with --apply to perform the renames."
      )
    end
  end

  defp print_changes(%{changes: []}), do: Mix.shell().info("No slugs to rename.")

  defp print_changes(%{changes: changes}) do
    Enum.each(changes, fn change ->
      Mix.shell().info(
        "#{change.kind} [#{change.state}] #{change.current} -> #{change.new}  (#{change.title})"
      )
    end)
  end
end
