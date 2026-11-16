defmodule Mix.Tasks.Kiln.Titles.Regenerate do
  @shortdoc "Re-derive record titles from a type's title_template (#2287)"

  @moduledoc """
  Re-derives the titles of a content type's existing records from its
  `title_template`, through the type's normal `:update` action (search, the
  change feed, webhooks and revisions all fire). Records with a pending working
  copy are skipped; they re-derive when the copy is published.

  A dynamic type's template change enqueues this on its own. For a **compiled**
  type the template ships with a deploy, so run it after one:

      mix kiln.titles.regenerate --type person

  `--org <uuid>` targets a specific site (defaults to the sole org).
  """

  use Mix.Task

  @switches [type: :string, org: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    org_id = opts[:org] || KilnCMS.Accounts.default_org_id()
    type = opts[:type] || Mix.raise("pass --type <name>")

    ct =
      KilnCMS.CMS.ContentTypes.get(type, org_id) || Mix.raise("unknown content type #{type}")

    cond do
      is_nil(ct.title_template) ->
        Mix.shell().info("#{type} has no title_template; nothing to do.")

      true ->
        summary = KilnCMS.CMS.TitleRegeneration.run(ct, org_id)

        Mix.shell().info(
          "Done: #{summary.changed} retitled, #{summary.skipped} skipped (working copy), " <>
            "#{summary.failed} failed, #{summary.scanned} scanned."
        )
    end
  end
end
