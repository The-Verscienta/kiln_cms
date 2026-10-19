if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Kiln.Gen.Join do
    @example "mix kiln.gen.join recipe.ingredients"

    @moduledoc """
    Graduate a `:reference` custom field to a typed Ash join resource (R10 in
    `docs/relationships-plan.md`, decision D22).

    A relationship defined in the fields admin stores its connections in the
    shared `content_links` table. When one relationship needs a table of its
    own — typed, indexed columns for its link data, SQL that joins it
    directly — this task generates one, the way `mix kiln.gen.content --from`
    promotes a dynamic type.

    ## Example

    ```bash
    #{@example}
    ```

    ## Arguments

    * `field` - the field to graduate, as `<content type>.<field name>`. The
      content type may be compiled (`page`) or admin-defined (`recipe`).

    ## Options

    * `--org <slug>` - the organization whose field definition gives the
      schema (default: the default org). Field definitions are per-site.
    * `--module <Module>` - the join resource module (default
      `KilnCMS.CMS.<Type><Field>Link`, e.g. `KilnCMS.CMS.RecipeIngredientsLink`).
    * `--data-migration` - the second step: write the migration that copies
      the field's connections into the join table.

    ## What it generates

    A resource on the `KilnCMS.CMS` domain with:

    * `belongs_to :source` and `belongs_to :target`, to the two content
      resources (`KilnCMS.CMS.Entry` for an admin-defined type), with foreign
      keys that delete a connection when either record is purged, unless the
      field refused the target's purge (see "Target rules" below);
    * `position`, and one typed attribute per link field (R3) — `:string`,
      `:integer`, `:float`, `:boolean`, `:date` or `:naive_datetime`, required
      and defaulted as the link field is, a select's choices as a `one_of`
      validation;
    * a `unique_connection` identity on `[:source_id, :target_id]` and an
      index on `target_id` for reads from the target's side;
    * `Ash.Policy.Authorizer` policies: admins bypass; editors read and
      write; anyone else reads a connection only when they may read both
      records (`KilnCMS.CMS.Checks.LinkEndsReadable`); a read-only API key
      cannot write;
    * code interfaces `list_/get_/create_/update_/destroy_<type>_<field>_link`
      and the ordered `list_<...>_links_from` (by source) and
      `list_<...>_links_to` (by target).

    ## Target rules

    The field's rules about its targets (R1b, R5) come with it, and the task
    prints which, and how, with the diff (dry run included):

    * `on_target_delete: :restrict` — the target's foreign key is
      `on_delete: :restrict`, and purging a record something still connects
      to is refused first with the field's own error
      (`KilnCMS.CMS.JoinGraduation.check_restrict/1`).
    * `:clear` — `on_delete: :delete`: the connections go with the purged
      record, as clearing it out of each referrer did.
    * `:keep` — `on_delete: :delete` as well, which is a change: a foreign
      key cannot point at nothing, so a purge no longer leaves a broken
      reference behind.
    * `max_sources` — `change {KilnCMS.CMS.JoinGraduation.SourceCap,
      max_sources: n}` on the create: the same count under the same advisory
      lock as the field (`KilnCMS.CMS.ContentLinks.reconcile/1`).

    Like the schema, the rules are read from the `--org` definition.

    A field that links to **several target types** (R2) is refused: a typed
    join table has one foreign key per end. Split it into one field per
    target type first.

    ## The order

    Graduation is three steps, each its own command, because each needs the
    one before it to have run:

    ```bash
    # 1. The resource, then its table.
    mix kiln.gen.join recipe.ingredients
    mix ash.codegen graduate_recipe_ingredients && mix ash.migrate

    # 2. The copy. A second run, so its migration sorts after step 1's table.
    mix kiln.gen.join recipe.ingredients --data-migration
    mix ash.migrate

    # 3. Once the copy is verified (and deployed): delete the field definition
    #    and its stored values, so there is one source of truth.
    mix kiln.join.retire recipe.ingredients
    ```

    Steps 1 and 2 only write code: like any Igniter task they show the diff
    and apply it on confirmation (`--yes` to skip the prompt, `--dry-run` to
    only show it). Step 3 is `mix kiln.join.retire`, which refuses while any
    connection is not in the join table.
    """
    @shortdoc "Graduate a reference field to a typed Ash join resource"
    use Igniter.Mix.Task

    alias KilnCMS.CMS.JoinGraduation

    @domain KilnCMS.CMS
    @repo KilnCMS.Repo

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        positional: [:field],
        example: @example,
        schema: [org: :string, module: :string, data_migration: :boolean]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Mix.Task.run("app.start")
      opts = igniter.args.options
      spec = resolve!(igniter.args.positional.field, opts)

      if opts[:data_migration] do
        add_data_migration(igniter, spec, igniter.args.positional.field)
      else
        add_resource(igniter, spec)
      end
    end

    defp resolve!(field, opts) do
      resolve_opts = [
        org_id: resolve_org!(opts[:org]),
        module: opts[:module] && Igniter.Project.Module.parse(opts[:module])
      ]

      case JoinGraduation.resolve(field, resolve_opts) do
        {:ok, spec} -> spec
        {:error, message} -> Mix.raise(message)
      end
    end

    defp resolve_org!(nil), do: KilnCMS.Accounts.default_org_id()

    defp resolve_org!(slug) do
      # authorize?: false — an operator-run task resolving the org it was told
      # to read, as `mix kiln.gen.content --org` does (#1659).
      case KilnCMS.Accounts.get_organization_by_slug(slug, authorize?: false) do
        {:ok, %{id: id}} -> id
        _none -> Mix.raise("no organization with slug #{inspect(slug)}")
      end
    end

    defp add_resource(igniter, spec) do
      igniter
      |> Igniter.Project.Module.create_module(spec.module, resource_body(spec))
      |> Ash.Domain.Igniter.add_resource_reference(@domain, spec.module)
      |> add_interfaces(spec.module, interfaces(spec.base))
      |> Igniter.add_warning(rules_summary(spec))
      |> Igniter.add_notice(resource_notice(spec))
    end

    defp add_data_migration(igniter, spec, field) do
      case Igniter.Project.Module.module_exists(igniter, spec.module) do
        {true, igniter} ->
          igniter
          |> Igniter.Libs.Ecto.gen_migration(@repo, "copy_#{spec.table}",
            body: migration_body(spec, field),
            on_exists: :skip
          )
          |> Igniter.add_notice(migration_notice(spec, field))

        {false, igniter} ->
          Igniter.add_issue(
            igniter,
            "#{inspect(spec.module)} does not exist yet. Run `mix kiln.gen.join #{field}` " <>
              "and migrate its table first; the copy must sort after it."
          )
      end
    end

    defp add_interfaces(igniter, resource, interfaces) do
      Enum.reduce(interfaces, igniter, fn {name, definition}, igniter ->
        Ash.Domain.Igniter.add_new_code_interface(igniter, @domain, resource, name, definition)
      end)
    end

    @doc false
    # The domain's code interfaces for a join resource. Public for unit testing.
    def interfaces(base) do
      plural = "#{base}s"

      [
        {:"list_#{plural}", "define :list_#{plural}, action: :read"},
        {:"get_#{base}", "define :get_#{base}, action: :read, get_by: [:id]"},
        {:"list_#{plural}_from",
         "define :list_#{plural}_from, action: :from_source, args: [:source_id]"},
        {:"list_#{plural}_to",
         "define :list_#{plural}_to, action: :to_target, args: [:target_id]"},
        {:"create_#{base}", "define :create_#{base}, action: :create"},
        {:"update_#{base}", "define :update_#{base}, action: :update"},
        {:"destroy_#{base}", "define :destroy_#{base}, action: :destroy"}
      ]
    end

    @doc false
    # The body of the generated resource. Public for unit testing.
    def resource_body(spec) do
      link_names = Enum.map(spec.columns, &String.to_atom(&1.name))

      """
      @moduledoc \"\"\"
      The `#{spec.field}` reference field of `#{spec.source.type}` ("#{spec.label}"),
      graduated from `content_links` to a table of its own with
      `mix kiln.gen.join #{spec.source.type}.#{spec.field}` (D22, R10 in
      `docs/relationships-plan.md`).

      Each row connects one `#{spec.source.type}` to one `#{spec.target.type}`, in `position`
      order, with the field's link data as typed columns.
      #{purge_sentence(spec)}

      Who may do what: admins anything; editors read and write; anyone else
      reads a connection only when they may read **both** records, so a draft
      on either end stays hidden. Removing a connection is an edit of the
      source, not a hard delete of content, so editors may.
      \"\"\"
      use Ash.Resource,
        domain: #{inspect(@domain)},
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      postgres do
        table #{inspect(spec.table)}
        repo #{inspect(@repo)}

        references do
          reference :source, on_delete: :delete
          #{target_reference(spec)}
        end

        custom_indexes do
          # Reads from the target's side ("which #{spec.source.type} records use this
          # #{spec.target.type}"); the identity's index serves the source's.
          index [:target_id]
        end
      end

      actions do
        defaults [:read, :destroy]

        default_accept #{inspect([:source_id, :target_id, :position | link_names])}

        #{create_action(spec)}

        update :update do
          primary? true
          accept #{inspect([:position | link_names])}
        end

        # One #{spec.source.type}'s connections, in order.
        read :from_source do
          argument :source_id, :uuid, allow_nil?: false
          filter expr(source_id == ^arg(:source_id))
          prepare build(sort: [position: :asc])
        end

        # Every connection to one #{spec.target.type}.
        read :to_target do
          argument :target_id, :uuid, allow_nil?: false
          filter expr(target_id == ^arg(:target_id))
          prepare build(sort: [source_id: :asc, position: :asc])
        end
      end
      #{validations(spec.columns)}
      policies do
        # A read-only API key may not write, even on an admin account: before
        # the bypass so it cannot skip this.
        policy action_type([:create, :update, :destroy]) do
          forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
          authorize_if always()
        end

        bypass KilnCMS.CMS.Checks.OrgAdmin do
          authorize_if always()
        end

        # A connection names both of its records, so it is readable only when
        # both are: editors see every connection of their site, anyone else
        # only those whose two ends they may read.
        policy action_type(:read) do
          access_type :runtime
          authorize_if KilnCMS.CMS.Checks.OrgEditor
          authorize_if KilnCMS.CMS.Checks.LinkEndsReadable
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if KilnCMS.CMS.Checks.OrgEditor
        end
      end

      multitenancy do
        strategy :attribute
        attribute :org_id
        global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
      end

      attributes do
        uuid_primary_key :id

        attribute :org_id, :uuid do
          allow_nil? false
          default &KilnCMS.Accounts.default_org_id/0
          writable? false
          public? false
        end

        attribute :position, :integer do
          allow_nil? false
          default 0
          public? true
          constraints min: 0
        end
      #{Enum.map_join(spec.columns, "", &attribute/1)}
        timestamps()
      end

      relationships do
        belongs_to :source, #{inspect(spec.source.resource)} do
          allow_nil? false
          public? true
          attribute_writable? true
        end

        belongs_to :target, #{inspect(spec.target.resource)} do
          allow_nil? false
          public? true
          attribute_writable? true
        end

        belongs_to :organization, KilnCMS.Accounts.Organization do
          source_attribute :org_id
          define_attribute? false
          attribute_writable? false
          public? false
        end
      end

      identities do
        # One connection per pair, as the field refused duplicates.
        identity :unique_connection, [:source_id, :target_id]
      end

      @doc false
      # What this resource graduated from (#2024): `KilnCMS.CMS.JoinGraduation`
      # finds join resources by it, and names the field in their errors.
      def __kiln_join__ do
        #{inspect(%{field: spec.field, label: spec.label, source_type: spec.source.type, target_type: spec.target.type})}
      end
      """
    end

    # The rest of the moduledoc's paragraph: what a purge does.
    defp purge_sentence(%{on_target_delete: :restrict} = spec) do
      "Purging a `#{spec.source.type}` deletes its connections. Purging a\n" <>
        "`#{spec.target.type}` is refused while anything connects to it, as the\n" <>
        "field's `on_target_delete: :restrict` refused it."
    end

    defp purge_sentence(_spec), do: "Purging either record deletes its connections."

    # `:restrict` keeps it; `:clear` and `:keep` delete the connection, the
    # only thing a foreign key can do with a row that points at nothing.
    defp target_reference(%{on_target_delete: :restrict}) do
      """
      # on_target_delete: :restrict, graduated. `JoinGraduation.check_restrict/1`
          # refuses the purge first, with the field's own error.
          reference :target, on_delete: :restrict\
      """
    end

    defp target_reference(_spec), do: "reference :target, on_delete: :delete"

    defp create_action(%{max_sources: max} = spec) when is_integer(max) do
      """
      create :create do
            primary? true
            # max_sources: #{max}, graduated: at most #{max} #{spec.source.type} records per
            # #{spec.target.type}, counted under the field's own advisory lock.
            change {KilnCMS.CMS.JoinGraduation.SourceCap, max_sources: #{max}}
          end\
      """
    end

    defp create_action(_spec), do: "create :create, primary?: true"

    @doc false
    # Which of the field's target rules the resource carries, and how. A
    # warning, not a notice, so that a dry run prints it too. Public for unit
    # testing.
    def rules_summary(spec) do
      field = "#{spec.source.type}.#{spec.field}"

      """
      Target rules of #{field}, as graduated:
        * on_target_delete: #{inspect(spec.on_target_delete)} → #{delete_rule(spec.on_target_delete)}
        * max_sources: #{max_rule(spec.max_sources)}
      """
    end

    defp delete_rule(:restrict),
      do:
        "on_delete: :restrict on the target. Purging a connected record is still refused, " <>
          "with the same error."

    defp delete_rule(:clear),
      do: "on_delete: :delete. The connections go with the purged record, as before."

    defp delete_rule(:keep),
      do:
        "on_delete: :delete. This CHANGES what a purge does: a foreign key cannot point " <>
          "at nothing, so the connections are deleted with the purged record instead of " <>
          "staying as broken references. Set the field to :restrict first to keep " <>
          "purges refused instead."

    defp max_rule(nil), do: "none (no limit), as before."

    defp max_rule(max),
      do:
        "#{max} → JoinGraduation.SourceCap on create, under the field's own advisory lock. " <>
          "Still at most #{max} per target."

    defp attribute(column) do
      options =
        [
          "allow_nil? #{not column.required}",
          column.default != nil && "default #{inspect(column.default)}",
          "public? true"
        ]
        |> Enum.filter(& &1)
        |> Enum.map_join("", &"\n      #{&1}")

      """

        # Link field "#{column.label}" (#{column.field_type}).
        attribute :#{column.name}, #{inspect(column.kind)} do#{options}
        end
      """
    end

    # A select link field keeps its choices.
    defp validations(columns) do
      case Enum.filter(columns, &(&1.options != [])) do
        [] ->
          ""

        selects ->
          lines =
            Enum.map_join(selects, "", fn column ->
              "\n    validate one_of(:#{column.name}, #{inspect(column.options)})"
            end)

          "\nvalidations do#{lines}\nend\n"
      end
    end

    @doc false
    # The generated data migration's body. Public for unit testing.
    def migration_body(spec, field) do
      """
      # Generated by `mix kiln.gen.join #{field} --data-migration` (R10).
      #
      # Copies the `#{spec.field}` reference field's connections from
      # `content_links` into #{inspect(spec.module)}'s table, in every
      # organization: ends, position and link values. A connection to or from a
      # record that no longer exists is not copied (a foreign key cannot point
      # at nothing). Safe to run twice (ON CONFLICT DO NOTHING).
      #
      # The field keeps working until `mix kiln.join.retire #{field}`, which
      # checks this copy is complete before deleting it.
      def up do
        execute(\"\"\"
      #{indent(JoinGraduation.copy_sql(spec), 4)}
        \"\"\")
      end

      # Nothing to undo that dropping the table (the codegen migration's own
      # `down`) would not, and deleting rows here could take connections made
      # since the copy with them.
      def down, do: :ok
      """
    end

    defp indent(text, n) do
      pad = String.duplicate(" ", n)

      text
      |> String.trim_trailing()
      |> String.split("\n")
      |> Enum.map_join("\n", &(pad <> &1))
    end

    defp resource_notice(spec) do
      field = "#{spec.source.type}.#{spec.field}"

      """
      Added #{inspect(spec.module)}, a typed join resource for #{field}, and its
      code interfaces on #{inspect(@domain)}. Nothing has moved yet: the field
      keeps working from content_links until step 3.

      Next:
        1. Create its table:
             mix ash.codegen graduate_#{spec.source.type}_#{spec.field} && mix ash.migrate
        2. Generate the copy (a second run, so it sorts after step 1):
             mix kiln.gen.join #{field} --data-migration && mix ash.migrate
        3. Once the copy is verified and deployed, retire the field:
             mix kiln.join.retire #{field}

      Optional: navigate from the content resources by hand, e.g. on
      #{inspect(spec.source.resource)}:
        has_many :#{spec.field}_links, #{inspect(spec.module)} do
          destination_attribute :source_id
          sort position: :asc
        end
      """
    end

    defp migration_notice(spec, field) do
      """
      Added a migration copying #{field}'s connections into #{inspect(spec.module)}.

      Next:
        * mix ash.migrate (and deploy it).
        * Check the copy, then retire the field — the check is part of it, and it
          deletes nothing until every connection is in the new table:
             mix kiln.join.retire #{field} --dry-run
             mix kiln.join.retire #{field}
      """
    end
  end
end
