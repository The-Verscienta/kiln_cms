defmodule Mix.Tasks.Kiln.Join.Retire do
  @shortdoc "Retire a reference field once its connections are in a join resource"

  @moduledoc """
  The last step of graduating a `:reference` field to a typed join resource
  (R10 in `docs/relationships-plan.md`): delete the field definition, and with
  it the field's stored values and `content_links` edges, so the join
  resource is the one source of truth.

  Run it **after** the copy has been migrated and checked:

  ```bash
  mix kiln.gen.join recipe.ingredients                   # resource
  mix ash.codegen graduate_recipe_ingredients && mix ash.migrate
  mix kiln.gen.join recipe.ingredients --data-migration  # copy
  mix ash.migrate
  mix kiln.join.retire recipe.ingredients --dry-run      # check
  mix kiln.join.retire recipe.ingredients                # retire
  ```

  It retires the field in every organization that defines it, and refuses —
  deleting nothing — unless, in each one:

    * the join resource is compiled with a column for every link field;
    * every connection whose two records exist has a join row with the same
      ends, position and link values (a connection made after the copy ran
      has none: re-run the copy migration's SQL, or make the connection again
      in the new table);
    * no record holds a value for the field without an edge
      (`mix kiln.links.backfill` writes them);
    * no working copy holds an unpublished value for the field (publish or
      discard it first).

  Connections to or from a purged record were never copied, and go with the
  field. Retiring deletes data — the field's values in `custom_fields`, which
  delivery, the APIs and fired artifacts served — so it asks before it does,
  unless `--yes`.

  On a release, run `KilnCMS.Release.retire_join_field/2` against the live
  node instead.

  ## Options

    * `--module <Module>` — the join resource, if it was generated with
      `--module` (default `KilnCMS.CMS.<Type><Field>Link`).
    * `--org <slug>` — the organization whose definition gives the link
      fields (default: the default org), as for `mix kiln.gen.join`.
    * `--dry-run` — check only; print the report and delete nothing.
    * `--yes` — do not ask before deleting.
  """
  use Mix.Task

  alias KilnCMS.CMS.JoinGraduation

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, positional} =
      OptionParser.parse!(argv,
        strict: [module: :string, org: :string, dry_run: :boolean, yes: :boolean]
      )

    field =
      case positional do
        [field] -> field
        _other -> Mix.raise("usage: mix kiln.join.retire <type>.<field> [--dry-run] [--yes]")
      end

    spec = resolve!(field, opts)

    case JoinGraduation.retire(spec, dry_run: true) do
      {:ok, :dry_run, reports} ->
        print(reports)
        after_check(spec, field, opts)

      {:error, %{} = reports} ->
        print(reports)
        Mix.raise("#{field} cannot retire yet: see the counts above. Nothing was deleted.")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp after_check(spec, field, opts) do
    cond do
      opts[:dry_run] -> Mix.shell().info("Dry run: nothing was deleted.")
      opts[:yes] || confirm?(field) -> retire!(spec, field)
      true -> Mix.shell().info("Nothing was deleted.")
    end
  end

  defp resolve!(field, opts) do
    org_id =
      case opts[:org] do
        nil ->
          KilnCMS.Accounts.default_org_id()

        slug ->
          # authorize?: false — an operator-run task resolving the org it was
          # told to read (#1659).
          case KilnCMS.Accounts.get_organization_by_slug(slug, authorize?: false) do
            {:ok, %{id: id}} -> id
            _none -> Mix.raise("no organization with slug #{inspect(slug)}")
          end
      end

    module = opts[:module] && Module.concat([opts[:module]])

    case JoinGraduation.resolve(field, org_id: org_id, module: module) do
      {:ok, spec} -> spec
      {:error, message} -> Mix.raise(message)
    end
  end

  defp confirm?(field) do
    Mix.shell().yes?(
      "Delete the #{field} field definition, its stored values and its content_links edges?"
    )
  end

  # The check runs again inside the deleting transaction: a connection made
  # while the operator read the prompt is caught there.
  defp retire!(spec, field) do
    case JoinGraduation.retire(spec) do
      {:ok, :retired, reports} ->
        Mix.shell().info("Retired #{field} in #{map_size(reports)} organization(s).")

      {:error, %{} = reports} ->
        print(reports)
        Mix.raise("#{field} changed since the check: see the counts above. Nothing was deleted.")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp print(reports) do
    Enum.each(reports, fn {org_id, report} ->
      Mix.shell().info("""
      Organization #{org_id}:
        #{report.copied} of #{report.edges} connections copied, #{report.missing} missing
        #{report.broken} broken (to or from a purged record; not copied)
        #{report.unmirrored} records with a value but no edge
        #{report.pending} unpublished working copies holding a value
      """)
    end)
  end
end
