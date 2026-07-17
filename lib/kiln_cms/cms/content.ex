# The injected `quote` is intentionally one long block — it mirrors a complete
# content-resource definition, which is most readable kept together rather than
# fragmented across helpers.
# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule KilnCMS.CMS.Content do
  @moduledoc """
  Shared scaffolding for editorial content types (decision D4 — content types
  are compile-time Ash resources, not a runtime meta-model).

  `use KilnCMS.CMS.Content, type: :page` gives a resource the full content
  behaviour — embedded block tree, version history (AshPaperTrail), the
  draft → in_review → published → archived workflow (AshStateMachine), scheduled
  publishing + nightly trash purge (AshOban), soft-delete (AshArchival),
  full-text search, the standard SEO/scheduling fields, the role-based policies,
  and the standard relationships (author, category, featured image, tags,
  related-self) — so a new content type only has to declare what's unique to it.

  ## Options

    * `:type` (required) — the singular content type atom, e.g. `:page`. Drives
      the GraphQL/JSON:API type names and, by convention, the join resources
      (`PageTag`, `RelatedPage`) and the table (`"pages"`).
    * `:plural` — the plural for interface names and the delivery URL segment;
      defaults to `"\#{type}s"`. Set it for irregular nouns (e.g. `:modality` →
      `"modalities"`) so discovery and dispatch match the generated interfaces.
    * `:table` — the Postgres table; defaults to `"\#{type}s"`.
    * `:domain` — the Ash domain the resource is registered on. Defaults to
      `KilnCMS.CMS` (the core CMS). Project-specific content types pass their own
      domain (e.g. `Verscienta.Catalog`) so the reusable core stays
      project-agnostic; list that domain in `:content_domains` (see
      `KilnCMS.CMS.ContentTypes`) so it is discovered everywhere.
    * `:excerpt?` — include an `excerpt` attribute (listings/feeds). Default `false`.
    * `:published?` — add a `:published` read (published-only, newest first).
      Default `false`.
    * `:dynamic?` — this resource is the shared **generic entry** tier backing
      admin-defined content types (decision D17, used only by
      `KilnCMS.CMS.Entry`). Adds a required `type_definition` relationship,
      scopes the slug identity and the public reads by `type_definition_id`,
      and **omits** the per-type JSON:API/GraphQL surface and the
      `__kiln_content_type__` discovery hook (dynamic types are discovered
      from `TypeDefinition` rows, not modules). Default `false`.

  Per-type extras (custom attributes, extra actions) are declared in the using
  module as usual — Spark merges them with what this macro injects.
  """
  # Days trashed content is retained before the nightly auto-purge.
  @trash_retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  # Days before an abandoned "Untitled …" scaffold draft (never given content)
  # is swept to the trash.
  @untitled_sweep_days Application.compile_env(:kiln_cms, [:drafts, :untitled_sweep_days], 7)

  @doc false
  # Safety net for reads exposed on the public API: when neither the caller
  # (Ash.Query.limit) nor the paginator bounded the query, cap it so a broad
  # search can't return every matching row — and so the semantic search's
  # distance sort keeps a LIMIT the HNSW index can serve.
  def cap_unbounded(query, default \\ 50) do
    if query.limit || query.page, do: query, else: Ash.Query.limit(query, default)
  end

  @doc false
  # Shared by the `:search_semantic` / `:search_semantic_published` prepares:
  # embed the query and order by cosine distance (nearest first). Returns
  # nothing when semantic search is disabled or the query can't be embedded.
  def semantic_sort(query) do
    with true <- KilnCMS.Search.semantic?(),
         {:ok, vector} <- KilnCMS.Search.embed_query(Ash.Query.get_argument(query, :query)) do
      query
      |> Ash.Query.sort([{:semantic_distance, {%{query_vector: vector}, :asc}}])
      |> cap_unbounded()
    else
      # Disabled, or the query couldn't be embedded — no semantic results.
      _ -> Ash.Query.limit(query, 0)
    end
  end

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)
    plural = Keyword.get(opts, :plural, "#{type}s")
    table = Keyword.get(opts, :table, "#{type}s")
    domain = Keyword.get(opts, :domain, KilnCMS.CMS)
    excerpt? = Keyword.get(opts, :excerpt?, false)
    dynamic? = Keyword.get(opts, :dynamic?, false)

    # `published?:` is accepted for backward compatibility but ignored: the
    # `/published` feed (read + route + GraphQL query) is universal since the
    # official client (#300) — every delivery consumer needs a server-side
    # published-only index, not just the blog (#297).
    _ = Keyword.get(opts, :published?, false)

    # Derive the per-type names from `type` by the project's naming convention.
    resource = __CALLER__.module
    related_name = :"related_#{type}s"
    related_arg = :"related_#{type}_ids"

    # AshOban worker/scheduler module names (kept identical to hand-written ones).
    pub_worker = Module.concat([resource, Workers, PublishScheduled])
    pub_scheduler = Module.concat([resource, Schedulers, PublishScheduled])
    unpub_worker = Module.concat([resource, Workers, UnpublishScheduled])
    unpub_scheduler = Module.concat([resource, Schedulers, UnpublishScheduled])
    purge_worker = Module.concat([resource, Workers, PurgeTrashed])
    purge_scheduler = Module.concat([resource, Schedulers, PurgeTrashed])
    sweep_worker = Module.concat([resource, Workers, SweepUntitled])
    sweep_scheduler = Module.concat([resource, Schedulers, SweepUntitled])

    accept =
      [:title, :slug] ++
        if(excerpt?, do: [:excerpt], else: []) ++
        if(dynamic?, do: [:type_definition_id], else: []) ++
        [
          :blocks,
          :seo_title,
          :seo_description,
          :seo_image,
          :canonical_url,
          :locale,
          :audience,
          :custom_fields,
          :scheduled_at,
          :unpublish_at,
          :category_id,
          :featured_image_id
        ]

    extensions = [
      AshPaperTrail.Resource,
      AshStateMachine,
      AshOban,
      AshArchival.Resource,
      AshJsonApi.Resource,
      AshGraphql.Resource,
      AshAdmin.Resource
    ]

    excerpt_attribute =
      if excerpt? do
        quote do
          attribute :excerpt, :string, public?: true
        end
      end

    published_read =
      quote do
        # Public delivery: published content, newest first. Universal (#300):
        # every type — not just the blog — needs a server-side published-only
        # index a keyed delivery caller can't widen to drafts (#297).
        read :published do
          filter expr(^ref(:state) == :published)

          # Filter/sort by admin-defined custom fields (typed JSONB access —
          # see the preparation). Declared before the default-sort build so a
          # `custom_sort` outranks `published_at` but not an explicit `sort`.
          argument :custom_filter, :map
          argument :custom_sort, :string
          prepare KilnCMS.CMS.Preparations.CustomFieldQuery

          prepare build(sort: [published_at: :desc])

          # Paginated for headless feed consumers (offset + keyset). `required?:
          # false` keeps `CMS.list_published_*` returning a plain list, but
          # `max_page_size` caps any explicit `page:` request — the public blog
          # index (see `ContentController.blog_index/2`) pages through it rather
          # than loading every row into memory.
          pagination offset?: true,
                     keyset?: true,
                     countable: true,
                     required?: false,
                     max_page_size: 100,
                     default_limit: 25
        end
      end

    # The matching GraphQL query for the `:published` read. Offset-paginated
    # for parity with the JSON:API `/published` feed (#195) — the `:published`
    # action caps results at `max_page_size` (100, default 25) so the delivery
    # surface can't be asked to load every published row at once.
    published_query =
      quote do
        list unquote(:"published_#{type}s"), :published, paginate_with: :offset
      end

    # JSON:API route for the published feed.
    published_route =
      quote do
        index :published, route: "/published"
      end

    # The headless surface. Compiled types each get their own typed schema;
    # the entry tier gets ONE generic surface shared by every dynamic type —
    # per-type typed schemas at runtime are impossible (Absinthe schemas are
    # compile-time), and that's the promotion pitch (D17). Consumers scope by
    # the filterable `type_name` calculation instead of a typed root.
    api_blocks =
      if dynamic? do
        quote do
          graphql do
            type :entry

            # Real-time headless: notifies on every entry write, resolved per
            # subscriber through the policy-scoped :read — anonymous
            # subscribers only ever receive published-visible data.
            subscriptions do
              pubsub KilnCMSWeb.Endpoint

              subscribe :entry_changed do
                action_types [:create, :update, :destroy]
                read_action :read
              end
            end

            # Curated, read-only public surface (D7) — the same delivery reads
            # compiled types expose, over the shared entry tier. All are
            # policy/state-filtered, so anonymous callers see published rows only.
            queries do
              get :entry_by_slug, :public_by_slug do
                identity false
              end

              list :entry_translations, :published_translations

              # The published index (newest first), across all dynamic types —
              # scope by the `type_name` filter like the plain list.
              list :published_entries, :published, paginate_with: :offset

              # `paginate_with: nil` keeps these plain lists (the pre-pagination
              # schema shape); the actions' prepare caps unpaginated reads.
              list :search_entries, :search, paginate_with: nil
              list :semantic_search_entries, :search_semantic, paginate_with: nil
              list :autocomplete_entries, :autocomplete

              # Published-only delivery twins (#297) — state pinned server-side.
              list :search_published_entries, :search_published, paginate_with: nil

              list :semantic_search_published_entries, :search_semantic_published,
                paginate_with: nil

              list :autocomplete_published_entries, :autocomplete_published
            end
          end

          json_api do
            type "entry"

            # Same compound-document surface as the compiled tier.
            includes [
              :tags,
              :category,
              :featured_image,
              :content_links,
              :incoming_links,
              unquote(related_name)
            ]

            routes do
              base "/entries"

              # One collection for all dynamic types — filter by the public
              # `type_name` calculation (`?filter[type_name]=recipe`).
              index :read
              index :search, route: "/search"
              index :search_semantic, route: "/semantic-search"
              index :autocomplete, route: "/autocomplete"
              # Published-only delivery twins (#297) — same query surface
              # minus `state`, filtered server-side, so a keyed service
              # caller can't be widened to drafts.
              index :search_published, route: "/search/published"
              index :search_semantic_published, route: "/semantic-search/published"
              index :autocomplete_published, route: "/autocomplete/published"
              unquote(published_route)
              get :read
            end
          end
        end
      else
        quote do
          graphql do
            type unquote(type)

            # Real-time headless: notifies on create/update/destroy, resolved
            # per subscriber through the policy-scoped :read — anonymous
            # subscribers only ever receive published-visible data.
            subscriptions do
              pubsub KilnCMSWeb.Endpoint

              subscribe unquote(:"#{type}_changed") do
                action_types [:create, :update, :destroy]
                read_action :read
              end
            end

            # Curated, read-only public surface (D7 — deliberate exposure). The
            # GraphQL endpoint is a *delivery* API: it exposes published-content
            # reads only. Authoring/workflow actions (create/update/publish/…) are
            # intentionally NOT surfaced here — they run through the admin editor
            # (and the bearer-authenticated JSON:API), behind the role policies.
            queries do
              # Published-content delivery: one record by slug+locale, and every
              # published locale variant of a slug (hreflang alternates). Both reads
              # are state-filtered, so anonymous callers only ever see published rows.
              # `identity false` exposes the action's own slug/locale arguments
              # instead of the default `id` lookup.
              get unquote(:"#{type}_by_slug"), :public_by_slug do
                identity false
              end

              list unquote(:"#{type}_translations"), :published_translations

              # The published index (newest first).
              unquote(published_query)

              # Headless search surface. Keyword + semantic search and typo-tolerant
              # title autocomplete, per content type. `paginate_with: nil` keeps
              # these plain lists (the pre-pagination schema shape); the actions'
              # prepare caps unpaginated reads instead.
              list unquote(:"search_#{type}s"), :search, paginate_with: nil
              list unquote(:"semantic_search_#{type}s"), :search_semantic, paginate_with: nil
              list unquote(:"autocomplete_#{type}s"), :autocomplete

              # Published-only delivery twins (#297) — state pinned server-side.
              list unquote(:"search_published_#{type}s"), :search_published, paginate_with: nil

              list unquote(:"semantic_search_published_#{type}s"), :search_semantic_published,
                paginate_with: nil

              list unquote(:"autocomplete_published_#{type}s"), :autocomplete_published
            end
          end

          json_api do
            type unquote(Atom.to_string(type))

            # Compound documents: the relationships a consumer may `include=`
            # (AshJsonApi rejects anything not declared here). Content links
            # come in both directions so headless consumers can join relation
            # edges (and their kind/position/metadata) without extra routes.
            # `author` stays excluded: User is deliberately not a JSON:API
            # resource (PII redaction, #183).
            includes [
              :tags,
              :category,
              :featured_image,
              :content_links,
              :incoming_links,
              unquote(related_name)
            ]

            routes do
              # `:plural` is documented as "the delivery URL segment" — honor it
              # here too instead of the naive `"#{type}s"`, which misroutes
              # irregular nouns (`:modality` → `/modalitys`). Identical for every
              # regular type (page → /pages, post → /posts).
              base unquote("/#{plural}")

              # Collection + single-record reads for headless consumers. Filtering
              # (`filter[...]`), sorting (`sort=`) and pagination (`page[...]`) are
              # derived from the `:read` action and the resource's public fields —
              # documented in `docs/json-api.md`.
              index :read
              index :search, route: "/search"
              # Semantic (vector) search over the same surface as GraphQL's
              # `semanticSearch*` (#186). Degrades to no results when embeddings are
              # unavailable (KilnCMS.Search.semantic? false).
              index :search_semantic, route: "/semantic-search"
              index :autocomplete, route: "/autocomplete"
              # Published-only delivery twins (#297) — same query surface
              # minus `state`, filtered server-side, so a keyed service
              # caller can't be widened to drafts.
              index :search_published, route: "/search/published"
              index :search_semantic_published, route: "/semantic-search/published"
              index :autocomplete_published, route: "/autocomplete/published"
              unquote(published_route)
              # `/:id` last so it can't shadow the static sub-paths above.
              get :read
            end
          end
        end
      end

    # A slug identifies a record within its locale — and, on the generic entry
    # tier, within its dynamic type.
    slug_identity = if dynamic?, do: [:type_definition_id, :slug, :locale], else: [:slug, :locale]

    # Public delivery reads. Both are consumed with `authorize?: false`
    # (anonymous headless/CDN delivery), so their filter is the *sole* security
    # boundary — it must gate the audience axis too, not just publish state
    # (see the read policy). On the entry tier they are additionally scoped by
    # the dynamic type, since slugs are only unique per type.
    public_reads =
      if dynamic? do
        quote do
          read :public_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false
            argument :type_definition_id, :uuid, allow_nil?: false

            filter expr(
                     ^ref(:state) == :published and ^ref(:audience) == :public and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale) and
                       ^ref(:type_definition_id) == ^arg(:type_definition_id)
                   )
          end

          read :published_translations do
            argument :slug, :string, allow_nil?: false
            argument :type_definition_id, :uuid, allow_nil?: false

            filter expr(
                     ^ref(:state) == :published and ^ref(:audience) == :public and
                       ^ref(:slug) == ^arg(:slug) and
                       ^ref(:type_definition_id) == ^arg(:type_definition_id)
                   )
          end
        end
      else
        quote do
          read :public_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false

            filter expr(
                     ^ref(:state) == :published and ^ref(:audience) == :public and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale)
                   )
          end

          # Every published locale variant of a slug, for hreflang alternates
          # and the language switcher.
          read :published_translations do
            argument :slug, :string, allow_nil?: false

            filter expr(
                     ^ref(:state) == :published and ^ref(:audience) == :public and
                       ^ref(:slug) == ^arg(:slug)
                   )
          end
        end
      end

    # Headless search reads, generated in pairs (#297): keyword search,
    # semantic search, and autocomplete each ship a `*_published` delivery
    # twin whose `state == :published` filter is pinned **server-side** — the
    # search counterpart of the plain index vs `:published`. The read policy
    # alone doesn't protect delivery consumers here: a bearer API key
    # authorizes as the account that minted it, so with an editor/admin key
    # the base actions silently match drafts. The twins cannot be widened by
    # any credential, and they drop the `state` facet argument (dead weight
    # against the pinned filter). Both flavors come from one template so
    # their query surfaces can't drift.
    join_and = fn clauses ->
      Enum.reduce(clauses, fn clause, acc -> quote(do: unquote(acc) and unquote(clause)) end)
    end

    pinned_state = quote(do: ^ref(:state) == :published)

    # The optional facets shared by keyword + semantic search — category,
    # author, tags (content carrying any of them), custom fields, and (base
    # flavor only) workflow state. `custom_filter` is a facet, not a sort:
    # relevance/distance is the order unless the caller passes an explicit
    # `sort` (see the prepare in each action).
    facet_args = fn published? ->
      [
        quote(do: argument(:category_id, :uuid)),
        quote(do: argument(:author_id, :uuid)),
        if(published?, do: nil, else: quote(do: argument(:state, :atom))),
        quote(do: argument(:tag_ids, {:array, :uuid})),
        quote(do: argument(:custom_filter, :map)),
        quote(do: prepare(KilnCMS.CMS.Preparations.CustomFieldQuery))
      ]
      |> Enum.reject(&is_nil/1)
    end

    facet_clauses = fn published? ->
      [
        quote(do: is_nil(^arg(:category_id)) or ^ref(:category_id) == ^arg(:category_id)),
        quote(do: is_nil(^arg(:author_id)) or ^ref(:author_id) == ^arg(:author_id)),
        if(published?,
          do: nil,
          else: quote(do: is_nil(^arg(:state)) or ^ref(:state) == ^arg(:state))
        ),
        quote(do: is_nil(^arg(:tag_ids)) or exists(tags, ^ref(:id) in ^arg(:tag_ids)))
      ]
      |> Enum.reject(&is_nil/1)
    end

    # Exposed on the public API (JSON:API index routes, GraphQL lists) —
    # without a bound, a broad query returns every matching row. For semantic
    # search the bound isn't just response size: an `ORDER BY embedding <=>
    # $1` without a LIMIT can't use the HNSW index — Postgres computes the
    # distance for every embedded row.
    search_pagination =
      quote do
        pagination offset?: true,
                   keyset?: true,
                   countable: true,
                   required?: false,
                   max_page_size: 100,
                   default_limit: 25
      end

    # Locale-aware full-text search over the trigger-maintained, weighted
    # `search_vector`. Scopes results to one `locale` (default: the configured
    # default) and stems with that locale's text-search config
    # (`kiln_regconfig/1`), so French content is matched with French rules,
    # etc. The prepare resolves the locale (setting it back so the filter sees
    # it too), then orders by relevance (ts_rank over the weighted vector —
    # title hits outrank body hits), newest to break ties. `Ash.Query.sort/2`
    # APPENDS: these keys rank after whatever the caller already sorted on, so
    # an explicit JSON:API/GraphQL `sort` overrides relevance and relevance
    # degrades to the tiebreaker. That contract is pinned by test ("explicit
    # sort= overrides relevance", JsonApiTest) — don't switch to
    # prepend/unsort without meaning to.
    search_read = fn name, published? ->
      filter_ast =
        join_and.(
          List.wrap(if(published?, do: pinned_state)) ++
            [
              quote(do: ^ref(:locale) == ^arg(:locale)),
              quote do
                fragment(
                  "search_vector @@ plainto_tsquery(kiln_regconfig(?), ?)",
                  ^arg(:locale),
                  ^arg(:query)
                )
              end
            ] ++ facet_clauses.(published?)
        )

      quote do
        read unquote(name) do
          argument :query, :string, allow_nil?: false
          argument :locale, :string

          unquote(search_pagination)

          unquote_splicing(facet_args.(published?))

          filter expr(unquote(filter_ast))

          prepare fn query, _context ->
            locale = Ash.Query.get_argument(query, :locale) || KilnCMS.I18n.default_locale()
            q = Ash.Query.get_argument(query, :query)

            query
            |> Ash.Query.set_argument(:locale, locale)
            |> Ash.Query.sort([
              {:search_rank, {%{locale: locale, query: q}, :desc}},
              {:inserted_at, :desc}
            ])
            |> KilnCMS.CMS.Content.cap_unbounded()
          end
        end
      end
    end

    # Semantic search: embed the query and return embedded content ordered by
    # cosine distance (nearest first), backed by the HNSW index. Returns
    # nothing when semantic search is disabled or the query can't be embedded.
    semantic_read = fn name, published? ->
      filter_ast =
        join_and.(
          List.wrap(if(published?, do: pinned_state)) ++
            [
              quote(do: not is_nil(^ref(:embedding))),
              quote(do: ^ref(:locale) == ^arg(:locale))
            ] ++ facet_clauses.(published?)
        )

      quote do
        read unquote(name) do
          argument :query, :string, allow_nil?: false
          argument :locale, :string

          unquote(search_pagination)

          unquote_splicing(facet_args.(published?))

          filter expr(unquote(filter_ast))

          prepare fn query, _context ->
            locale = Ash.Query.get_argument(query, :locale) || KilnCMS.I18n.default_locale()

            query
            |> Ash.Query.set_argument(:locale, locale)
            |> KilnCMS.CMS.Content.semantic_sort()
          end
        end
      end
    end

    # Typo-tolerant title autocomplete: same-locale rows whose title matches
    # the prefix (case-insensitive) or is trigram-similar (handles typos),
    # ordered by similarity, capped at 10. The base flavor has no state facet
    # at all — anonymous callers are policy-filtered to published, but a keyed
    # editor caller gets draft suggestions; the published twin is the only
    # way to narrow it.
    autocomplete_read = fn name, published? ->
      filter_ast =
        join_and.(
          List.wrap(if(published?, do: pinned_state)) ++
            [
              quote(do: ^ref(:locale) == ^arg(:locale)),
              quote do
                fragment("? ILIKE ? || '%'", ^ref(:title), ^arg(:prefix)) or
                  fragment("? <% ?", ^arg(:prefix), ^ref(:title))
              end
            ]
        )

      quote do
        read unquote(name) do
          argument :prefix, :string, allow_nil?: false
          argument :locale, :string

          filter expr(unquote(filter_ast))

          prepare fn query, _context ->
            locale = Ash.Query.get_argument(query, :locale) || KilnCMS.I18n.default_locale()
            prefix = Ash.Query.get_argument(query, :prefix)

            query
            |> Ash.Query.set_argument(:locale, locale)
            |> Ash.Query.sort([{:title_similarity, {%{prefix: prefix}, :desc}}])
            |> Ash.Query.limit(10)
          end
        end
      end
    end

    search_actions =
      quote do
        (unquote_splicing([
           search_read.(:search, false),
           search_read.(:search_published, true),
           semantic_read.(:search_semantic, false),
           semantic_read.(:search_semantic_published, true),
           autocomplete_read.(:autocomplete, false),
           autocomplete_read.(:autocomplete_published, true)
         ]))
      end

    # The generic entry tier belongs to its admin-defined type; slugs, public
    # reads and (Phase 3) delivery are all scoped through it.
    type_definition_rel =
      if dynamic? do
        quote do
          belongs_to :type_definition, KilnCMS.CMS.TypeDefinition do
            allow_nil? false
            public? true
          end
        end
      end

    # The owning dynamic type's name string, as an expression calculation so
    # headless consumers can filter the generic entries surface by type
    # (`filter[type_name]=recipe` / `filter: {typeName: {eq: "recipe"}}`)
    # without resolving TypeDefinition ids.
    type_name_calc =
      if dynamic? do
        quote do
          calculate :type_name, :string, expr(type_definition.name) do
            public? true
          end
        end
      end

    # Compiled types export the discovery hooks `KilnCMS.CMS.ContentTypes`
    # scans for. The entry tier deliberately does NOT — dynamic types are
    # discovered from `TypeDefinition` rows — and instead marks itself so
    # shared changes (custom fields, cache busting) can branch.
    markers =
      if dynamic? do
        quote do
          @doc false
          def __kiln_dynamic_entry__, do: true
        end
      else
        quote do
          # Marks this resource as a KilnCMS content type and records its
          # singular type atom, so generated types appear everywhere with no
          # extra wiring.
          def __kiln_content_type__, do: unquote(type)

          # The plural used for code-interface names, the delivery URL segment,
          # and discovery.
          def __kiln_content_plural__, do: unquote(plural)

          # The plural as an atom, for keying per-type sections (e.g. global
          # search results). `String.to_atom` is safe here: it runs inside the
          # `unquote` at macro expansion, on a compile-time macro option (D4 —
          # no user input), never per-request.
          # sobelow_skip ["DOS.StringToAtom"]
          def __kiln_content_section__, do: unquote(String.to_atom(plural))
        end
      end

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(extensions),
        # The primary :read carries the (optional) custom-field filter/sort
        # arguments + preparation, which no-op when absent — internal uses of
        # the primary read (relationship loads, policy checks) are unaffected.
        primary_read_warning?: false

      unquote(api_blocks)

      # Content-focused AshAdmin overrides (issue #25). AshAdmin is the dev/CRUD
      # inspector, not the editor — these just make it pleasant: group the content
      # types together, show editorial columns at a glance instead of every raw
      # attribute, surface only the meaningful actions (hiding the internal
      # `:set_embedding` / `:set_published_version_id` / scheduler writes), and
      # label content with its title wherever it's referenced.
      admin do
        resource_group :content

        # Friendly datatable: identity + timing. Internal columns (search_text,
        # embedding, embedded_at, lock_version, published_version_id) are
        # deliberately omitted. `:state` is omitted too: it's added by the
        # AshStateMachine transformer, which on a clean compile runs *after*
        # AshAdmin's ValidateTableColumns — so listing it raises "Invalid table
        # columns: [:state]". `:published_at` conveys publish status here, and the
        # full `:state` is still shown/editable on the record page.
        table_columns [:title, :slug, :audience, :locale, :published_at, :updated_at]

        format_fields published_at: {KilnCMS.CMS.Admin, :format_datetime, []},
                      scheduled_at: {KilnCMS.CMS.Admin, :format_datetime, []},
                      unpublish_at: {KilnCMS.CMS.Admin, :format_datetime, []},
                      inserted_at: {KilnCMS.CMS.Admin, :format_datetime, []},
                      updated_at: {KilnCMS.CMS.Admin, :format_datetime, []}

        # Show title (not the UUID) when this content appears as a relationship,
        # and in relationship select/typeahead inputs on other resources.
        relationship_display_fields [:title]
        label_field :title

        # Trim the action lists to what a developer actually drives by hand. The
        # search/autocomplete reads and the scheduler/embedding writes are still
        # callable in code — they're just noise in the admin.
        read_actions [:read, :trashed]
        create_actions [:create]

        update_actions [
          :update,
          :submit_for_review,
          :return_to_draft,
          :publish,
          :unpublish,
          :archive,
          :restore,
          :restore_version
        ]

        destroy_actions [:destroy, :purge]

        # Handy derived values on the show view.
        show_calculations [:published, :word_count]

        form do
          field :seo_description, type: :long_text
          field :canonical_url, type: :short_text
        end
      end

      paper_trail do
        change_tracking_mode(:changes_only)
        store_action_name?(true)
        ignore_attributes([:inserted_at, :updated_at, :embedding, :embedded_at, :lock_version])
        # Background embedding writes aren't editorial changes — keep the
        # `:set_embedding` action out of the version history.
        ignore_actions([:set_embedding, :set_published_version_id])
        # No FK from version -> source, so a `:purge` can hard-delete a record
        # whose history exists. Versions of purged content are kept as audit rows.
        reference_source?(false)
        mixin({KilnCMS.CMS.VersionPolicies, :policies, []})
        version_extensions(authorizers: [Ash.Policy.Authorizer])
      end

      state_machine do
        initial_states [:draft]
        default_initial_state :draft

        transitions do
          transition :submit_for_review, from: :draft, to: :in_review
          transition :return_to_draft, from: :in_review, to: :draft
          transition :publish, from: [:draft, :in_review], to: :published
          transition :publish_scheduled, from: [:draft, :in_review], to: :published
          transition :unpublish, from: :published, to: :draft
          transition :unpublish_scheduled, from: :published, to: :draft
          transition :archive, from: [:draft, :in_review, :published], to: :archived
          # Archive must not be a one-way door (audit U-H3): a mistaken (or
          # bulk) archive is recoverable by returning the record to draft.
          transition :unarchive, from: :archived, to: :draft
        end
      end

      # Background publishing of scheduled content + nightly purge of old trash.
      oban do
        triggers do
          trigger :publish_scheduled do
            action :publish_scheduled
            queue :scheduling
            scheduler_cron "* * * * *"

            where expr(
                    ^ref(:state) in [:draft, :in_review] and not is_nil(^ref(:scheduled_at)) and
                      ^ref(:scheduled_at) <= now()
                  )

            worker_read_action :read
            worker_module_name unquote(pub_worker)
            scheduler_module_name unquote(pub_scheduler)
          end

          # The embargo end: take published content back down once its
          # `unpublish_at` passes (same minute-cron cadence as scheduled
          # publishing).
          trigger :unpublish_scheduled do
            action :unpublish_scheduled
            queue :scheduling
            scheduler_cron "* * * * *"

            where expr(
                    ^ref(:state) == :published and not is_nil(^ref(:unpublish_at)) and
                      ^ref(:unpublish_at) <= now()
                  )

            worker_read_action :read
            worker_module_name unquote(unpub_worker)
            scheduler_module_name unquote(unpub_scheduler)
          end

          trigger :purge_trashed do
            action :purge
            read_action :trashed
            worker_read_action :trashed
            queue :default
            scheduler_cron "0 3 * * *"

            where expr(^ref(:archived_at) <= ago(unquote(@trash_retention_days), :day))

            worker_module_name unquote(purge_worker)
            scheduler_module_name unquote(purge_scheduler)
          end

          # "New page/post" persists an "Untitled …" record immediately, so
          # abandoning the editor leaves an empty scaffold behind. Sweep drafts
          # that still have the scaffold title, no blocks, and no edits for
          # @untitled_sweep_days into the trash (soft delete — restorable for
          # the retention window above).
          trigger :sweep_untitled do
            action :destroy
            queue :default
            scheduler_cron "45 3 * * *"

            where expr(
                    ^ref(:state) == :draft and
                      like(^ref(:title), "Untitled %") and
                      fragment("coalesce(cardinality(?), 0) = 0", ^ref(:blocks)) and
                      ^ref(:updated_at) <= ago(unquote(@untitled_sweep_days), :day)
                  )

            worker_read_action :read
            worker_module_name unquote(sweep_worker)
            scheduler_module_name unquote(sweep_scheduler)
          end
        end
      end

      # Let `:trashed` see soft-deleted rows and `:purge` actually hard-delete.
      archive do
        exclude_read_actions([:trashed])
        exclude_destroy_actions([:purge])
      end

      postgres do
        table unquote(table)
        repo KilnCMS.Repo

        # The `:search` action's GIN index is on the trigger-maintained
        # `search_vector` column (locale-weighted tsvector) — created in the
        # `add_locale_weighted_search` migration alongside the trigger, since the
        # column isn't an Ash-managed attribute.
        custom_indexes do
          # HNSW index for approximate nearest-neighbour search over embeddings,
          # using cosine distance (`<=>`). The `embedding vector_cosine_ops`
          # column string carries the opclass through to the generated DDL.
          index ["embedding vector_cosine_ops"],
            name: unquote("#{table}_embedding_hnsw_index"),
            using: "hnsw"

          # Trigram GIN index on title for typo-tolerant autocomplete (the `%`
          # similarity operator + `similarity(...)`). `gin_trgm_ops` opclass is
          # carried through via the column string.
          index ["title gin_trgm_ops"],
            name: unquote("#{table}_title_trgm_index"),
            using: "gin"
        end
      end

      actions do
        default_accept unquote(accept)

        # Primary read, tuned for headless list consumers (JSON:API `index
        # :read`). Offset paging for page-numbered UIs, keyset for stable deep
        # cursors; `default_limit`/`max_page_size` bound the response size and
        # `countable` lets clients ask for a total. `required?: false` (with the
        # default `paginate_by_default?: false`) keeps internal `CMS.list_*`
        # callers returning plain lists — only callers that pass `page:` (the
        # JSON:API layer, when `page[...]` is supplied) get a paginator.
        read :read do
          primary? true

          # Filter/sort by admin-defined custom fields — one JSONB map, so the
          # derived `filter[...]`/`sort=` machinery can't reach into it. The
          # preparation turns these into typed `get_path` predicates/sort keys
          # validated against the FieldDefinition registry (docs/json-api.md).
          argument :custom_filter, :map
          argument :custom_sort, :string
          prepare KilnCMS.CMS.Preparations.CustomFieldQuery

          pagination offset?: true,
                     keyset?: true,
                     countable: true,
                     required?: false,
                     max_page_size: 100,
                     default_limit: 25
        end

        # Soft-delete (AshArchival). Non-atomic so the cache-busting after_action
        # change can run.
        destroy :destroy do
          primary? true
          require_atomic? false
        end

        create :create do
          primary? true
          # Stamp the acting user as the author (system/seed creates leave nil).
          change relate_actor(:author, allow_nil?: true)
          # Set the many-to-many links from lists of ids (nil/omitted = no change).
          argument :tag_ids, {:array, :uuid}
          argument unquote(related_arg), {:array, :uuid}
          change manage_relationship(:tag_ids, :tags, type: :append_and_remove)

          change manage_relationship(unquote(related_arg), unquote(related_name),
                   type: :append_and_remove
                 )

          change KilnCMS.CMS.Changes.ApplyCustomFields
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          validate KilnCMS.CMS.Validations.SeoUrls
          validate KilnCMS.CMS.Validations.ScheduleOrder
        end

        update :update do
          primary? true
          require_atomic? false
          # Optimistic concurrency: only apply if the in-memory `lock_version`
          # still matches the row, incrementing it on success. Two editors saving
          # the same draft no longer silently clobber each other — the loser gets
          # a `StaleRecord` error and must reload.
          change optimistic_lock(:lock_version)
          argument :tag_ids, {:array, :uuid}
          argument unquote(related_arg), {:array, :uuid}
          change manage_relationship(:tag_ids, :tags, type: :append_and_remove)

          change manage_relationship(unquote(related_arg), unquote(related_name),
                   type: :append_and_remove
                 )

          change KilnCMS.CMS.Changes.ApplyCustomFields
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding

          # Edits to already-published content fire a `<type>.updated` webhook;
          # `only_when: :published` keeps draft edits and autosaves silent.
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "updated", only_when: :published}
          validate KilnCMS.CMS.Validations.SeoUrls
          validate KilnCMS.CMS.Validations.ScheduleOrder
        end

        # Debounced draft autosave from the editor. Writes the same content as
        # `:update`, but as a distinct action so its PaperTrail versions are
        # tagged `version_action_name: :autosave` and can be coalesced — a save
        # per editor pause would otherwise flood history (issue #32).
        # `CoalesceAutosaveVersions` collapses the trailing run of autosave
        # versions into a single snapshot after each save. Drafts only (enforced
        # by the editor); no `updated` webhook (draft edits are silent anyway).
        update :autosave do
          require_atomic? false
          change optimistic_lock(:lock_version)
          argument :tag_ids, {:array, :uuid}
          argument unquote(related_arg), {:array, :uuid}
          change manage_relationship(:tag_ids, :tags, type: :append_and_remove)

          change manage_relationship(unquote(related_arg), unquote(related_name),
                   type: :append_and_remove
                 )

          change KilnCMS.CMS.Changes.ApplyCustomFields
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.CoalesceAutosaveVersions
          validate KilnCMS.CMS.Validations.SeoUrls
          validate KilnCMS.CMS.Validations.ScheduleOrder
        end

        # Keyword search, semantic search, and autocomplete — each paired with
        # its `*_published` delivery twin (state pinned server-side, #297).
        # Generated from one template above (`search_read`/`semantic_read`/
        # `autocomplete_read`), where the behavior is documented. All go
        # through the read policy, so anonymous callers only ever match
        # published content — the twins exist for *keyed* delivery callers,
        # whose editor/admin identity would otherwise widen the base actions
        # to drafts.
        unquote(search_actions)

        update :submit_for_review do
          require_atomic? false
          change transition_state(:in_review)
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :submitted_for_review}
        end

        update :return_to_draft do
          require_atomic? false
          change transition_state(:draft)
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :returned_to_draft}
        end

        update :publish do
          require_atomic? false
          change transition_state(:published)
          change set_attribute(:published_at, &DateTime.utc_now/0)
          change KilnCMS.CMS.Changes.RecordPublishedVersion
          change KilnCMS.CMS.Changes.FireArtifacts
          change KilnCMS.CMS.Changes.NotifyWebhooks
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}
        end

        update :publish_scheduled do
          # Run by the AshOban scheduler once `scheduled_at` has passed.
          require_atomic? false
          change transition_state(:published)
          change set_attribute(:published_at, &DateTime.utc_now/0)
          change set_attribute(:scheduled_at, nil)
          change KilnCMS.CMS.Changes.RecordPublishedVersion
          change KilnCMS.CMS.Changes.FireArtifacts
          change KilnCMS.CMS.Changes.NotifyWebhooks
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}
        end

        update :restore_version do
          # Reverts content fields to a previous PaperTrail version (captured as
          # a new version itself). Workflow state is left unchanged.
          require_atomic? false
          accept []
          argument :version_id, :uuid, allow_nil?: false
          change KilnCMS.CMS.Changes.RestoreVersion
        end

        update :unpublish do
          require_atomic? false
          change transition_state(:draft)
          change KilnCMS.CMS.Changes.ClearPublishedVersion
          change KilnCMS.CMS.Changes.DeleteArtifacts
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "unpublished"}
        end

        update :unpublish_scheduled do
          # Run by the AshOban scheduler once `unpublish_at` has passed — the
          # scheduled mirror of `:unpublish`, clearing the schedule so the
          # trigger can't re-fire.
          require_atomic? false
          change transition_state(:draft)
          change set_attribute(:unpublish_at, nil)
          change KilnCMS.CMS.Changes.ClearPublishedVersion
          change KilnCMS.CMS.Changes.DeleteArtifacts
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "unpublished"}
        end

        update :archive do
          require_atomic? false
          change transition_state(:archived)
        end

        # Sends archived content back to draft (the state-machine inverse of
        # :archive).
        update :unarchive do
          require_atomic? false
          change transition_state(:draft)
        end

        # Public delivery reads (`:public_by_slug`, `:published_translations`)
        # — defined above as `public_reads`, entry-tier variants scoped by
        # `type_definition_id`.
        unquote(public_reads)

        unquote(published_read)

        # Soft-deleted ("trashed") records — the only read that bypasses
        # AshArchival's automatic `is_nil(archived_at)` filter.
        read :trashed do
          # Keyset pagination is required for the AshOban auto-purge trigger;
          # `required?: false` keeps plain `list_trashed_*` calls returning lists.
          pagination keyset?: true, required?: false
          filter expr(not is_nil(^ref(:archived_at)))
        end

        # Bring a soft-deleted record back by clearing its archival timestamp.
        update :restore do
          accept []
          require_atomic? false
          change set_attribute(:archived_at, nil)
        end

        # Permanent hard delete (bypasses archival). Used by "Empty trash" and the
        # nightly auto-purge; admin/system only via the destroy policy.
        destroy :purge do
          require_atomic? false
        end

        # Background-maintained semantic embedding, written by
        # `KilnCMS.Search.EmbeddingWorker`. Kept separate from `:update` so it
        # neither re-runs the content changes nor enqueues another embedding, and
        # it's excluded from PaperTrail (see the `paper_trail` block).
        update :set_embedding do
          require_atomic? false
          argument :embedding, KilnCMS.Search.Vector, allow_nil?: false
          change set_attribute(:embedding, arg(:embedding))
          change set_attribute(:embedded_at, &DateTime.utc_now/0)
        end

        # Internal: wire `published_version_id` after publish without a new
        # PaperTrail row (see `ignore_actions` above).
        update :set_published_version_id do
          require_atomic? false
          accept [:published_version_id]
        end
      end

      # Invalidate the public delivery cache whenever published content changes
      # (applies to every create/update/destroy action; no-ops for draft-only
      # writes — see the change module).
      changes do
        change KilnCMS.CMS.Changes.BustContentCache, on: [:create, :update, :destroy]
      end

      policies do
        # The AshOban scheduler publishes scheduled content as a trusted job.
        bypass AshOban.Checks.AshObanInteraction do
          authorize_if always()
        end

        # API keys default to **read-only** access (headless/third-party
        # delivery): a `:read` key can never mutate content, even one minted on
        # an editor/admin account. A `:read_write` key (LLM/automation authoring
        # via `/mcp` — docs/mcp.md) falls through to the owning user's role
        # policies below instead. Both run before the admin bypass so they
        # aren't short-circuited. Defense-in-depth: the JSON:API/GraphQL
        # delivery surface exposes only reads regardless (D7).
        policy action_type([:create, :update]) do
          forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
          authorize_if always()
        end

        # No key may destroy content, whatever its scope — an automation
        # credential has no business hard-deleting (archive/unpublish are
        # update actions, gated by the write scope above).
        policy action_type(:destroy) do
          forbid_if AshAuthentication.Checks.UsingApiKey
          authorize_if always()
        end

        # Admins may do anything.
        bypass actor_attribute_equals(:role, :admin) do
          authorize_if always()
        end

        # Read access combines the publishing workflow with the consumer-facing
        # audience (KilnCMS.CMS.Audiences) — the *read* axis, separate from the
        # editorial role:
        #   • editors (and admins, via the bypass above) see every record;
        #   • `:public` published content stays world-readable (anonymous
        #     headless delivery / public site);
        #   • audience-restricted published content is visible only to a
        #     signed-in reader who belongs to that audience.
        # Drafts/in-review/archived remain editors-only. `actor(:audiences)` is
        # nil for anonymous callers, so a gated record simply isn't authorized
        # (the `in` yields no match) rather than erroring.
        policy action_type(:read) do
          authorize_if actor_attribute_equals(:role, :editor)
          authorize_if expr(^ref(:state) == :published and ^ref(:audience) == :public)
          authorize_if expr(^ref(:state) == :published and ^ref(:audience) in ^actor(:audiences))
        end

        # Authoring and workflow transitions are reserved for editors (and admins
        # via the bypass above). Every state-machine action is an update action.
        # Granular RBAC (#332): an editor may author only the content types in
        # their `editable_types` scope — empty means all (the default), so
        # unrestricted editors are unchanged.
        policy action_type([:create, :update]) do
          authorize_if KilnCMS.CMS.Checks.EditableContentType
        end

        # Publishing is an admin approval step — editors submit for review instead.
        policy action([:publish, :publish_scheduled]) do
          authorize_if actor_attribute_equals(:role, :admin)
        end

        # Sending reviewed content back to the author is admin-only.
        policy action(:return_to_draft) do
          authorize_if actor_attribute_equals(:role, :admin)
        end

        # Hard deletes are admin-only.
        policy action_type(:destroy) do
          forbid_if always()
        end

        # Trash browsing and restore are admin-only too (mirrors delete).
        policy action([:trashed, :restore]) do
          forbid_if always()
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :title, :string, allow_nil?: false, public?: true
        attribute :slug, :string, allow_nil?: false, public?: true

        unquote(excerpt_attribute)

        # Typed polymorphic block tree (Kiln v2 — decision D11). `BlockUnion`'s
        # cast is legacy-tolerant: legacy stored rows convert lazily on read and
        # legacy params still cast, so this flip needs no data migration. Rich-text
        # HTML / media URLs are sanitized inside the cast (replacing SanitizeBlocks).
        # Not `public?` — the auto JSON:API/GraphQL surface can't render a union of
        # embedded resources cleanly, and the v2 API surface is the *fired*
        # artifacts (`KilnCMS.Firing.Engine.read/3`), not the raw editable tree.
        # Still accepted on create/update (see `accept`) and read internally by the
        # editor/firing/delivery.
        attribute :blocks, {:array, KilnCMS.CMS.BlockUnion} do
          default []
          public? false
        end

        attribute :seo_title, :string, public?: true
        attribute :seo_description, :string, public?: true
        # og:image URL and rel=canonical for SEO/social.
        attribute :seo_image, :string, public?: true
        attribute :canonical_url, :string, public?: true
        attribute :locale, :string, default: "en", public?: true

        # Consumer-facing access tier (KilnCMS.CMS.Audiences). `:public` (the
        # default) keeps a published record world-readable; any other audience
        # restricts published reads to signed-in users who belong to it (see the
        # read policy). Public on the API so headless clients can label gated
        # content — the policy, not field hiding, is the access boundary.
        attribute :audience, :atom do
          constraints one_of: KilnCMS.CMS.Audiences.all()
          default :public
          allow_nil? false
          public? true
        end

        # Admin-UI-defined custom fields (decision D4 — schema stays compile-time,
        # but *fields* are data-driven). Values are keyed by `FieldDefinition.name`
        # and coerced/validated against the registry on write by
        # `Changes.ApplyCustomFields`. Public so headless clients get the extra
        # fields; the editor renders one input per definition.
        attribute :custom_fields, :map do
          default %{}
          allow_nil? false
          public? true
        end

        attribute :published_at, :utc_datetime_usec, public?: true

        # PaperTrail version id of the immutable snapshot taken at the last
        # publish. Internal — not exposed via the public APIs.
        attribute :published_version_id, :uuid

        # When set in the future, the AshOban scheduler publishes this record once
        # the time passes (cleared on publish).
        attribute :scheduled_at, :utc_datetime_usec, public?: true

        # The embargo end: when set, the AshOban scheduler unpublishes this
        # record (back to draft, artifacts deleted) once the time passes
        # (cleared on unpublish).
        attribute :unpublish_at, :utc_datetime_usec, public?: true

        # Denormalized plain-text maintained by `Changes.SetSearchText` and
        # queried by the `search` action. Internal.
        attribute :search_text, :string

        # Semantic-search embedding of `search_text`, plus when it was last
        # computed. Maintained by `KilnCMS.Search.EmbeddingWorker`; internal
        # (never exposed via the APIs, ignored by PaperTrail). `nil` until first
        # embedded, or always when semantic search is disabled.
        attribute :embedding, KilnCMS.Search.Vector
        attribute :embedded_at, :utc_datetime_usec

        # Optimistic-concurrency version, bumped on every `:update` (see the
        # action's `optimistic_lock`). Internal.
        attribute :lock_version, :integer, allow_nil?: false, default: 1, public?: false

        # Public so headless consumers can serialize and sort on them (Ash 3
        # defaults attributes to public?: false, and AshJsonApi rejects a
        # non-public sort field as invalid_sort — sort=-inserted_at simply
        # errored before this). Still non-writable; `published_at` remains the
        # editorial recency field for published feeds.
        timestamps(public?: true)
      end

      relationships do
        unquote(type_definition_rel)

        # The user who authored this record. Nullable so existing/system content
        # without an actor is valid. Exposed via the public APIs, but only the
        # safe byline fields (`id`, `name`) serialize — email, role, and notify
        # prefs are `public? false` on User (#183), so `?include=author` /
        # `author { ... }` can never return author PII.
        belongs_to :author, KilnCMS.Accounts.User do
          allow_nil? true
          public? true
        end

        # Many-to-one: belongs to at most one category (one-to-many inverse).
        belongs_to :category, KilnCMS.CMS.Category do
          allow_nil? true
          public? true
        end

        # Many-to-one: the lead/hero image.
        belongs_to :featured_image, KilnCMS.CMS.MediaItem do
          allow_nil? true
          public? true
        end

        # Many-to-many: free-form tags via the shared polymorphic `Tagging` join
        # (one table for every content type — no per-type join resource).
        many_to_many :tags, KilnCMS.CMS.Tag do
          through KilnCMS.CMS.Tagging
          source_attribute_on_join_resource :subject_id
          destination_attribute_on_join_resource :tag_id
          public? true
        end

        # Self-referential many-to-many: editor-curated "related" content via the
        # shared polymorphic `ContentLink` (new rows default to `kind: :related`).
        many_to_many unquote(related_name), unquote(resource) do
          through KilnCMS.CMS.ContentLink
          source_attribute_on_join_resource :source_id
          destination_attribute_on_join_resource :target_id
          public? true
        end

        # The raw outgoing `ContentLink` rows for this record (it as `source`),
        # so relations that carry a payload are reachable: each row exposes
        # `kind`, `position`, `label` and the `metadata` map. Use this (instead
        # of the typed `related_*` m2m above) when you need the link attributes —
        # e.g. `load: [content_links: []]` then read `link.metadata`.
        has_many :content_links, KilnCMS.CMS.ContentLink do
          destination_attribute :source_id
          public? true
        end

        # The reverse: links pointing *at* this record (it as `target`) — "what
        # links to me", with the same per-link payload.
        has_many :incoming_links, KilnCMS.CMS.ContentLink do
          destination_attribute :target_id
          public? true
        end
      end

      calculations do
        unquote(type_name_calc)

        # Convenience flag for the published state (no `?` suffix — GraphQL names
        # can't contain it).
        calculate :published, :boolean, expr(^ref(:state) == :published) do
          public? true
        end

        # Total word count across the embedded block tree.
        calculate :word_count, :integer, KilnCMS.CMS.Calculations.WordCount do
          public? true
        end

        # Full-text relevance of a row against a query — higher is more
        # relevant. Used to order the `:search` action; `query`/`locale` are the
        # same values that action filters on, so the weighted `search_vector` is
        # ranked with the matching locale's text-search config. Internal.
        calculate :search_rank,
                  :float,
                  expr(
                    fragment(
                      "ts_rank(search_vector, plainto_tsquery(kiln_regconfig(?), ?))",
                      ^arg(:locale),
                      ^arg(:query)
                    )
                  ) do
          argument :locale, :string, allow_nil?: false
          argument :query, :string, allow_nil?: false
        end

        # A highlighted snippet of the match — the surrounding text with the
        # query terms wrapped in `<mark>`. Loaded on demand by passing the same
        # `query`/`locale`, e.g. `load: [highlight: %{query: q, locale: loc}]`.
        # NOTE: `ts_headline` does not HTML-escape the source, so renderers must
        # escape everything except the `<mark>` tags before treating it as HTML.
        calculate :highlight,
                  :string,
                  expr(
                    fragment(
                      "ts_headline(kiln_regconfig(?), coalesce(search_text, ''), plainto_tsquery(kiln_regconfig(?), ?), 'StartSel=<mark>, StopSel=</mark>, MaxFragments=2, MaxWords=18, MinWords=5')",
                      ^arg(:locale),
                      ^arg(:locale),
                      ^arg(:query)
                    )
                  ) do
          argument :locale, :string, allow_nil?: false
          argument :query, :string, allow_nil?: false
          public? true
        end

        # Word-level trigram similarity of the autocomplete prefix to the title
        # (0–1, higher is closer) — matches a short query against any word in the
        # title. Orders the `:autocomplete` action. Internal.
        calculate :title_similarity,
                  :float,
                  expr(fragment("word_similarity(?, ?)", ^arg(:prefix), ^ref(:title))) do
          argument :prefix, :string, allow_nil?: false
        end

        # Cosine distance (pgvector `<=>`) between a row's embedding and the
        # query vector — smaller is more similar. Used to order the
        # `:search_semantic` action. Internal (sorting only).
        # The query vector is inlined as a float array, so cast it to `vector`
        # for pgvector's `<=>` cosine-distance operator.
        calculate :semantic_distance,
                  :float,
                  expr(fragment("? <=> ?::vector", ^ref(:embedding), ^arg(:query_vector))) do
          argument :query_vector, KilnCMS.Search.Vector, allow_nil?: false
        end
      end

      identities do
        identity :unique_slug, unquote(slug_identity)
      end

      unquote(markers)
    end
  end
end
