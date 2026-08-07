defmodule Mix.Tasks.Kiln.Media.RegenerateVariants do
  @shortdoc "Re-enqueue responsive/modern-format variants for existing media (#473)"

  @moduledoc """
  Re-runs `KilnCMS.Media.VariantWorker` over the media library, so a variant
  configuration change reaches images that were uploaded before it — the
  "Regenerate Thumbnails" analogue.

      mix kiln.media.regenerate_variants           # only what's missing
      mix kiln.media.regenerate_variants --all     # everything, config changed
      mix kiln.media.regenerate_variants --org <uuid>

  By default this only enqueues items **missing** a configured format, which is
  what a rollout of WebP/AVIF to an existing library needs and costs nothing for
  media already converted. Use `--all` after changing a *quality* or a target
  width, where the existing variants are present but no longer what the config
  asks for.

  Work runs on the `:media` Oban queue, whose concurrency throttles it — this
  task returns as soon as the jobs are enqueued, and a second run inside the
  hour is deduplicated rather than doubling the work.

  Originals are never rewritten: published documents point at them by key.
  """

  use Mix.Task

  @switches [all: :boolean, org: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    org_id = opts[:org] || KilnCMS.Accounts.default_org_id()
    formats = KilnCMS.ImageProcessor.variant_formats()

    Mix.shell().info(
      "Regenerating variants for org #{org_id} " <>
        "(formats: #{format_list(formats)}#{if opts[:all], do: ", all items", else: ", missing only"})"
    )

    %{enqueued: enqueued, scanned: scanned} =
      KilnCMS.Media.Regeneration.run(org_id, only_missing?: opts[:all] != true)

    Mix.shell().info(
      "Enqueued #{enqueued} of #{scanned} image(s). " <>
        "Watch the :media queue; originals are untouched."
    )
  end

  defp format_list([]), do: "source format only"
  defp format_list(formats), do: formats |> Enum.map_join(", ", &to_string/1)
end
