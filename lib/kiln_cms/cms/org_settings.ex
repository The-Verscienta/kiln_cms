# The injected `quote` is intentionally one long block — it mirrors a complete
# settings-resource definition, which is most readable kept together rather than
# fragmented across helpers. Same reasoning as `KilnCMS.CMS.Content` and
# `KilnCMS.CMS.Taxonomy`.
# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule KilnCMS.CMS.OrgSettings do
  @moduledoc """
  The shape every one-row-per-org settings resource shares (#1080).

  `SiteBranding`, `SiteCodeInjection`, `FormSpamSettings`,
  `SiteEditorialSettings`, `SiteLinkCheck`, `SiteCompliance`, `FeedSettings`,
  `SiteEmbedSettings` and `Federation.SiteFederation` are nine views of one
  idea: an admin-written row per organization, created lazily by an upsert on
  `:save` and never by a read, tenant-scoped, with the operator's config
  underneath as the default. They had grown into nine hand-copied blocks of
  the same DSL — the multitenancy strategy, the `writable?: false` `org_id`
  boundary, the `:one_per_org` identity, the upsert-on-identity `:save`, the
  `OrgAdmin` write policy, the `belongs_to :organization` — and the copying was
  the danger, not the length: the `global?` line is what keeps a tenant's row
  out of another tenant's read, and a tenth resource that omitted it would
  compile clean and be a cross-tenant read. #1077 also had to fix the resolver
  fallback direction on one of these and the same reasoning was not applied to
  the others, because nothing made them move together.

  This macro emits the shared half. A resource keeps its own body for what is
  genuinely its own — the settings attributes, extra actions, validations,
  `changes`, `paper_trail`/`oban` blocks — and Spark merges the two (repeating
  a DSL section appends to it), exactly as `KilnCMS.CMS.Taxonomy` does for the
  taxonomy resources.

  ## Options

    * `:table` (required) — the Postgres table.
    * `:accept` (required) — the settings attributes an admin writes:
      `default_accept`, and the `:save` upsert's fields unless
      `:upsert_fields` says otherwise.
    * `:upsert_fields` — what a conflicting `:save` overwrites. Defaults to
      `:accept`; a resource whose `:save` also derives a stored field (a
      measured icon size, a script hash) lists it here.
    * `:read` — who may read the row: `:public` (`authorize_if always()` — the
      value is rendered into public pages anyway), `:editor` (`OrgEditor`) or
      `:admin` (`OrgAdmin`, the default). Writes are always `OrgAdmin`.
    * `:update?` — whether to emit the primary `update :update`. Defaults to
      `true`.
    * `:save_arguments` — `[{name, type}]` arguments declared on `:save` and
      `:update` alike (a paired value a change derives a stored field from).
    * `:save_changes` — change modules run on `:save` and `:update` (not
      `:destroy`; a resource-wide bust belongs in its own `changes do` block).
    * `:admin_columns` — AshAdmin `table_columns`; when given, the
      `AshAdmin.Resource` extension and its `admin` block are emitted.
    * `:extensions` — further Ash extensions (`AshOban`, `AshPaperTrail.Resource`).
    * `:domain` — defaults to `KilnCMS.CMS`.

  ## The read side

  Three of these are read on every public request through a cached, layered
  resolver — `KilnCMS.Branding`, `KilnCMS.CodeInjection`, `KilnCMS.Feeds` —
  and that resolver's load-bearing details (never cache a `nil`; a mid-deploy
  missing table degrades rather than 500s; *what* it degrades to is a
  per-setting decision) are one function now too: `KilnCMS.OrgSettings.resolve/2`.
  """

  @doc """
  Every resource built on this macro, discovered rather than listed — the same
  way `KilnCMS.CMS.Taxonomy.searchable/0` finds taxonomy resources. A test
  pins that every one-row-per-org resource in the app is one of these, so the
  next one cannot be hand-rolled without failing it.
  """
  @spec all() :: [module()]
  def all do
    [KilnCMS.CMS, KilnCMS.Federation]
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :__kiln_org_settings__, 0))
    )
    |> Enum.sort()
  end

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    accept = Keyword.fetch!(opts, :accept)
    upsert_fields = Keyword.get(opts, :upsert_fields, accept)
    read = Keyword.get(opts, :read, :admin)
    update? = Keyword.get(opts, :update?, true)
    save_arguments = Keyword.get(opts, :save_arguments, [])
    save_changes = Keyword.get(opts, :save_changes, [])
    admin_columns = Keyword.get(opts, :admin_columns)
    extra_extensions = Keyword.get(opts, :extensions, [])
    domain = Keyword.get(opts, :domain, KilnCMS.CMS)

    unless read in [:public, :editor, :admin] do
      raise ArgumentError,
            "OrgSettings :read must be :public, :editor or :admin, got #{inspect(read)}"
    end

    extensions =
      if admin_columns, do: [AshAdmin.Resource | extra_extensions], else: extra_extensions

    read_check =
      case read do
        :public -> quote(do: always())
        :editor -> quote(do: KilnCMS.CMS.Checks.OrgEditor)
        :admin -> quote(do: KilnCMS.CMS.Checks.OrgAdmin)
      end

    argument_decls =
      for {name, type} <- save_arguments do
        quote do
          argument unquote(name), unquote(type)
        end
      end

    change_decls =
      for mod <- save_changes do
        quote do
          change unquote(mod)
        end
      end

    # Conditional DSL is spliced as a prebuilt fragment (or `nil`, a no-op),
    # the way `KilnCMS.CMS.Taxonomy` handles its sorted read.
    admin_block =
      if admin_columns do
        quote do
          admin do
            resource_group :content
            table_columns unquote(admin_columns)
          end
        end
      end

    update_action =
      if update? do
        quote do
          update :update do
            primary? true
            require_atomic? false
            unquote_splicing(argument_decls)
            unquote_splicing(change_decls)
          end
        end
      end

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(extensions)

      unquote(admin_block)

      postgres do
        table unquote(table)
        repo KilnCMS.Repo
      end

      actions do
        defaults [:read]

        default_accept unquote(accept)

        # The row is created lazily by this upsert on the one-per-org identity
        # — never by a read, so a site that never opened the page costs
        # nothing, and looking at a page is not a write.
        create :save do
          primary? true
          upsert? true
          upsert_identity :one_per_org
          upsert_fields unquote(upsert_fields)
          unquote_splicing(argument_decls)
          unquote_splicing(change_decls)
        end

        unquote(update_action)

        destroy :destroy do
          primary? true
          require_atomic? false
        end
      end

      policies do
        policy action_type(:read) do
          authorize_if unquote(read_check)
        end

        # Changing what a whole site does is an admin act, on every one of these.
        policy action_type([:create, :update, :destroy]) do
          authorize_if KilnCMS.CMS.Checks.OrgAdmin
        end
      end

      # The tenancy boundary (epic #336). `global?` is the security-relevant
      # line: it is what keeps one org's row out of another org's read, and it
      # is emitted here so a new settings resource cannot omit it.
      multitenancy do
        strategy :attribute
        attribute :org_id
        global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
      end

      attributes do
        uuid_primary_key :id

        # Set from the tenant (or the default org); never accepted from input.
        attribute :org_id, :uuid do
          allow_nil? false
          default &KilnCMS.Accounts.default_org_id/0
          writable? false
          public? false
        end

        timestamps()
      end

      relationships do
        belongs_to :organization, KilnCMS.Accounts.Organization do
          source_attribute :org_id
          define_attribute? false
          attribute_writable? false
          public? false
        end
      end

      identities do
        identity :one_per_org, [:org_id]
      end

      @doc false
      # Marker for `KilnCMS.CMS.OrgSettings.all/0`.
      def __kiln_org_settings__, do: %{table: unquote(table), read: unquote(read)}
    end
  end
end
