# The injected `quote` is intentionally one long block — it mirrors a complete
# taxonomy-resource definition, which is most readable kept together rather than
# fragmented across helpers. Same reasoning as `KilnCMS.CMS.Content`.
# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule KilnCMS.CMS.Taxonomy do
  @moduledoc """
  The shape every taxonomy resource shares (#530).

  `Category`, `Tag` and `TagGroup` are three views of one idea: a lightweight,
  editor-managed, world-readable lookup table, per-site, addressed by slug, and
  exposed identically over REST and GraphQL. They had grown into three
  near-verbatim copies of that shape — the extension list, the whole RBAC policy
  stack, the multitenancy strategy, the `writable?: false` `org_id` boundary, the
  slug-index workaround, and the JSON:API/GraphQL route shape were byte-identical
  in all three.

  That is the dangerous kind of duplication: changing the
  `ApiKeyWithoutWriteAccess`-before-bypass ordering, flipping `global?`, or making
  `org_id` writable on an admin path was a 3× edit where a miss leaves a silently
  broken security boundary rather than a failing test. And it had already drifted
  — `TagGroup` was the only one without a `:search` action, so tag groups were
  unfindable in `/search`, the command palette and the search API.

  This macro emits the shared half. A resource keeps its own body for what
  genuinely differs — relationships, aggregates, validations, extra indexes — and
  Spark merges the two (repeating a DSL section appends to it).

  ## Options

    * `:type` (required) — the singular type atom, e.g. `:tag_group`. Names the
      GraphQL type and the JSON:API `type`.
    * `:plural` — defaults to `"\#{type}s"`. Names the GraphQL list query, the
      table, the slug-index prefix, and the JSON:API route base (underscores
      dashed — `"/tag-groups"`, the convention `media_item` set). `Category`
      needs it.
    * `:includes` — JSON:API `includes`. Defaults to `[]`.
    * `:admin_columns` — AshAdmin `table_columns`. Defaults to
      `[:name, :slug, :inserted_at]`.
    * `:description?` — whether the resource carries a `description` (and
      therefore searches it). Defaults to `true`; `Tag` has none.
    * `:accept` — extra attributes for `default_accept`, on top of `name`,
      `slug` and (when present) `description`.
    * `:atomic_update?` — defaults to `true`. Set `false` where a validation has
      to read another row, which cannot run inside an atomic UPDATE.
    * `:read_sort` — a sort for the primary read, e.g. `[position: :asc]`. When
      given, the read is declared explicitly (and the primary-read warning is
      waived, since the sort is the point).
  """

  @doc """
  The taxonomy resources, as `{search section key, resource}`, sorted by key.

  The registry behind `KilnCMS.Search.global/2`'s taxonomy leg, which was a
  literal two-element list — which is how `TagGroup` came to be unfindable in
  search without anything failing.

  **Discovered, not listed.** A hand-written list here would be the same bug one
  layer up: a fourth taxonomy resource would get the `:search` action from the
  macro, a REST and GraphQL surface, and still be absent from `/search`, the
  command palette and `/api/search`. Every resource built on this macro exports
  `__kiln_taxonomy_section__/0`, and this finds them the same way
  `KilnCMS.CMS.ContentTypes.all/0` finds content types.
  """
  @spec searchable() :: [{atom(), module()}]
  def searchable do
    KilnCMS.CMS
    |> Ash.Domain.Info.resources()
    |> Enum.filter(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :__kiln_taxonomy_section__, 0))
    )
    |> Enum.map(&{&1.__kiln_taxonomy_section__(), &1})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)
    plural = Keyword.get(opts, :plural, "#{type}s")
    table = plural
    route_base = "/" <> String.replace(plural, "_", "-")
    includes = Keyword.get(opts, :includes, [])
    admin_columns = Keyword.get(opts, :admin_columns, [:name, :slug, :inserted_at])
    description? = Keyword.get(opts, :description?, true)
    atomic_update? = Keyword.get(opts, :atomic_update?, true)
    read_sort = Keyword.get(opts, :read_sort)

    accept =
      [:name, :slug] ++
        if(description?, do: [:description], else: []) ++
        Keyword.get(opts, :accept, [])

    slug_index = "#{table}_slug_lookup_index"
    # The plural as an atom: the GraphQL list query's name, and the search
    # section key. Built here, at expansion, from a literal option — never at
    # runtime from anything a request supplies.
    plural_atom = :"#{plural}"
    by_slug_query = :"#{type}_by_slug"

    description_attribute =
      if description? do
        quote do
          attribute :description, :string, public?: true
        end
      end

    # Name matched by substring or trigram word similarity (typo-tolerant, the
    # same operator as content autocomplete), description by substring where
    # there is one.
    search_filter =
      if description? do
        quote do
          filter expr(
                   fragment("? ILIKE '%' || ? || '%'", ^ref(:name), ^arg(:query)) or
                     fragment("? <% ?", ^arg(:query), ^ref(:name)) or
                     fragment("? ILIKE '%' || ? || '%'", ^ref(:description), ^arg(:query))
                 )
        end
      else
        quote do
          filter expr(
                   fragment("? ILIKE '%' || ? || '%'", ^ref(:name), ^arg(:query)) or
                     fragment("? <% ?", ^arg(:query), ^ref(:name))
                 )
        end
      end

    # A sorted primary read has to be declared rather than defaulted. The
    # warning it raises is about a primary read carrying behaviour; here the
    # sort IS the contract (every caller wants picker order), so it is waived.
    read_action =
      if read_sort do
        quote do
          read :read do
            primary? true
            prepare build(sort: unquote(read_sort))
          end
        end
      end

    defaults = if read_sort, do: [:destroy], else: [:read, :destroy]

    update_action =
      if atomic_update? do
        quote do
          update :update, primary?: true
        end
      else
        quote do
          update :update do
            primary? true
            require_atomic? false
          end
        end
      end

    quote do
      use Ash.Resource,
        domain: KilnCMS.CMS,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshJsonApi.Resource, AshGraphql.Resource, AshAdmin.Resource],
        primary_read_warning?: unquote(is_nil(read_sort))

      graphql do
        type unquote(type)

        # Taxonomy is world-readable (D7) — list them all and fetch one by slug,
        # so a headless frontend can build the same navigation, tag clouds and
        # filtered listings the console does.
        queries do
          list unquote(plural_atom), :read do
            paginate_with nil
          end

          get unquote(by_slug_query), :by_slug do
            identity false
          end
        end
      end

      json_api do
        # snake_case `type`, kebab-case route base — the convention media_item set.
        type unquote(to_string(type))
        includes unquote(includes)

        # JSON:API parity with the GraphQL taxonomy surface (#185).
        routes do
          base unquote(route_base)
          index :read
          get :by_slug, route: "/by-slug/:slug"
          # `/:id` last so it can't shadow the static sub-path above.
          get :read
        end
      end

      # AshAdmin: group taxonomy together and label by name (issue #25).
      admin do
        resource_group :taxonomy
        table_columns unquote(admin_columns)
        relationship_display_fields [:name]
        label_field :name
      end

      postgres do
        table unquote(table)
        repo KilnCMS.Repo

        # `:unique_slug` is the `org_id`-LEADING `(org_id, slug)` composite, which
        # Postgres can't seek for a tenant-less `by_slug` delivery read (reads set
        # no tenant under `global?: true`). This `all_tenants?: true` companion
        # keeps a plain `(slug)` index so those lookups still seek; redundant with
        # the composite once every taxonomy read threads the tenant (mirrors
        # content.ex).
        custom_indexes do
          index [:slug], name: unquote(slug_index), all_tenants?: true
        end
      end

      actions do
        defaults unquote(defaults)
        default_accept unquote(accept)

        create :create, primary?: true

        unquote(update_action)
        unquote(read_action)

        # Public delivery: fetch one by its slug (taxonomy is public).
        read :by_slug do
          get? true
          argument :slug, :string, allow_nil?: false
          filter expr(^ref(:slug) == ^arg(:slug))
        end

        # Taxonomy leg of global search. Closest names first, capped — taxonomy
        # is a small lookup table, so no trigram index is needed.
        read :search do
          argument :query, :string, allow_nil?: false

          unquote(search_filter)

          prepare fn query, _context ->
            q = Ash.Query.get_argument(query, :query)

            query
            |> Ash.Query.sort([{:name_similarity, {%{query: q}, :desc}}])
            |> Ash.Query.limit(10)
          end
        end
      end

      policies do
        # Read-scoped API keys can never write taxonomy, and no key may
        # hard-delete it — BEFORE the admin bypass, so a key on an admin account
        # can't skip it (mirrors the content policy; see
        # Checks.ApiKeyWithoutWriteAccess).
        policy action_type([:create, :update]) do
          forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
          authorize_if always()
        end

        policy action_type(:destroy) do
          forbid_if AshAuthentication.Checks.UsingApiKey
          authorize_if always()
        end

        # Admins may do anything.
        bypass KilnCMS.CMS.Checks.OrgAdmin do
          authorize_if always()
        end

        # Taxonomy is world-readable — it is referenced by published content and
        # served to public/headless frontends.
        policy action_type(:read) do
          authorize_if always()
        end

        # Managing taxonomy is reserved for editors (and admins via the bypass).
        policy action_type([:create, :update]) do
          authorize_if KilnCMS.CMS.Checks.OrgEditor
        end

        # Hard deletes are admin-only (allowed by the bypass; denied here for
        # every other role).
        policy action_type(:destroy) do
          forbid_if always()
        end
      end

      # Multi-tenancy (epic #336): taxonomy is per-site, partitioned by `org_id`
      # (Ash `:attribute` strategy — same axis as content). `global?: true` keeps
      # a tenant OPTIONAL: tenant-less reads/writes (editor, seeds, public
      # delivery) keep working and land in the default org (see the `org_id`
      # default below).
      multitenancy do
        strategy :attribute
        attribute :org_id
        global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
      end

      attributes do
        uuid_primary_key :id

        # The owning organization (epic #336). Set automatically from the tenant
        # on a scoped create, else defaults to the sole org; never accepted from
        # input (`writable?: false`, absent from `default_accept`) — the
        # cross-site boundary.
        attribute :org_id, :uuid do
          allow_nil? false
          default &KilnCMS.Accounts.default_org_id/0
          writable? false
          public? false
        end

        attribute :name, :string, allow_nil?: false, public?: true
        attribute :slug, :string, allow_nil?: false, public?: true

        unquote(description_attribute)

        timestamps()
      end

      relationships do
        # The owning organization — the tenant axis is the `org_id` attribute.
        belongs_to :organization, KilnCMS.Accounts.Organization do
          source_attribute :org_id
          define_attribute? false
          attribute_writable? false
          public? false
        end
      end

      calculations do
        # Trigram closeness (0–1) of a search query to the name — orders
        # `:search`. Internal (sorting only).
        calculate :name_similarity,
                  :float,
                  expr(fragment("word_similarity(?, ?)", ^arg(:query), ^ref(:name))) do
          argument :query, :string, allow_nil?: false
        end
      end

      identities do
        identity :unique_slug, [:slug]
      end

      # The marker `KilnCMS.CMS.Taxonomy.searchable/0` discovers this resource
      # by, and the search section key it contributes. Mirrors the
      # `__kiln_content_type__/0` marker `KilnCMS.CMS.Content` emits for
      # `ContentTypes.all/0`.
      @doc false
      def __kiln_taxonomy_section__, do: unquote(plural_atom)
    end
  end
end
