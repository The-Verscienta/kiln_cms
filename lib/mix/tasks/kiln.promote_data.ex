defmodule Mix.Tasks.Kiln.PromoteData do
  @shortdoc "Move a promoted dynamic type's data into its compiled table"

  @moduledoc """
  The data half of promoting an admin-defined dynamic content type into a
  compiled one (decision D17's graduation path). Run **after** the compiled
  resource exists and its migration is applied:

  ```bash
  mix kiln.gen.content --from recipe
  mix ash.codegen add_recipes && mix ash.migrate
  mix kiln.promote_data recipe
  ```

  In one transaction this moves the type's entries (ids preserved — taggings
  and content links keep working) and their version history into the compiled
  type's tables, purges its stale `:entry` artifacts/edges (re-fired on
  demand), re-scopes its custom-field definitions to the compiled type, and
  archives the `TypeDefinition`. See `KilnCMS.CMS.Promotion`.

  ## Options

    * `--into <type>` — promote into a different compiled type than `<name>`
      (rarely needed; the generator normally creates the same-named type).
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: [into: :string])

    case positional do
      [name] ->
        {:ok, %{entries: entries, versions: versions}} =
          KilnCMS.CMS.Promotion.promote!(name, into: opts[:into] || name)

        Mix.shell().info("""
        Promoted #{name}: moved #{entries} entries and #{versions} versions.

        * Custom-field definitions now belong to the compiled type — the editor
          keeps rendering them unchanged.
        * The TypeDefinition was archived; the compiled type owns the name and
          URL segment now.
        * Fired artifacts were dropped and will re-fire on demand.
        """)

      _other ->
        Mix.raise("usage: mix kiln.promote_data <type name> [--into <compiled type>]")
    end
  end
end
