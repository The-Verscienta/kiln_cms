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
  # For `semantic_floor/2` below — `Ash.Query.filter/2` is a macro. Scoped to
  # this module; the injected resource `quote` brings its own imports.
  require Ash.Query

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
         {:ok, vector} <- query_vector(query) do
      query
      |> Ash.Query.sort([{:semantic_distance, {%{query_vector: vector}, :asc}}])
      |> semantic_floor(vector)
      |> cap_unbounded()
    else
      # Disabled, or the query couldn't be embedded — no semantic results.
      _ -> Ash.Query.limit(query, 0)
    end
  end

  # Drop neighbours that are merely the *nearest* rather than actually related
  # (see `KilnCMS.Search.semantic_max_distance/0`). Off unless configured, so
  # this is inert for anyone who hasn't measured a cutoff for their model.
  #
  # `WHERE distance <= t ORDER BY distance LIMIT n` is pgvector's documented
  # thresholding shape: the ORDER BY still drives the HNSW index scan and the
  # bound is applied to the rows it walks, so this does not fall back to the
  # exact-scan behaviour `cap_unbounded/2` exists to prevent. It can return
  # fewer than `limit` rows — that is the entire point.
  defp semantic_floor(query, vector) do
    case KilnCMS.Search.semantic_max_distance() do
      nil ->
        query

      max_distance ->
        Ash.Query.filter(
          query,
          semantic_distance(query_vector: ^vector) <= ^max_distance
        )
    end
  end

  # A caller running this leg across many resources can embed the query once
  # and hand the vector down in the query context — `KilnCMS.Search.global/2`
  # does, because it fans out one search per content type and would otherwise
  # pay an identical embedding per section. Embedding is by far the most
  # expensive step in a semantic search, so that is the difference between one
  # embedding per request and one per registered type.
  #
  # `:unavailable` means the caller tried and failed; don't retry it here once
  # per section. No context at all means nobody embedded ahead of us — the
  # single-resource callers (the per-type search routes) land here.
  defp query_vector(query) do
    case query.context do
      %{query_vector: vector} when is_list(vector) -> {:ok, vector}
      %{query_vector: :unavailable} -> :error
      _ -> KilnCMS.Search.embed_query(Ash.Query.get_argument(query, :query))
    end
  end

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)
    plural = Keyword.get(opts, :plural, "#{type}s")
    table = Keyword.get(opts, :table, "#{type}s")
    domain = Keyword.get(opts, :domain, KilnCMS.CMS)
    excerpt? = Keyword.get(opts, :excerpt?, false)
    dynamic? = Keyword.get(opts, :dynamic?, false)

    # The schema.org @type this type's :json_ld surface fires as its main node
    # (#357, GEO) — e.g. "BlogPosting", "MedicalWebPage". Must be in
    # `KilnCMS.Firing.SchemaOrg.types/0`; unknown values fall back to Article
    # at fire time. Dynamic entries resolve theirs from the TypeDefinition row.
    schema_org_type = Keyword.get(opts, :schema_org_type, "Article")

    # Optional pathauto slug pattern (#454), e.g. "[yyyy]-[mm]-[title]" — see
    # `KilnCMS.Slug.Pattern`. Unknown tokens fail the build here; nil keeps
    # the default derivation (focus keyphrase → title).
    slug_pattern = opts |> Keyword.get(:slug_pattern) |> KilnCMS.Slug.Pattern.validate!()

    # Optional pathauto ALIAS pattern (#485), e.g.
    # "/acupuncture/needle/size/[field:size]" — auto-fills `path_alias`.
    alias_pattern =
      opts |> Keyword.get(:alias_pattern) |> KilnCMS.Slug.Pattern.validate!(usage: :alias)

    # Optional default SEO patterns (#805), e.g. "[title] | [site-name]" — see
    # `KilnCMS.Seo.Pattern`. Unknown tokens fail the build here. Resolved at
    # render time for records whose own field is blank; nil = no default.
    seo_title_pattern =
      opts |> Keyword.get(:seo_title_pattern) |> KilnCMS.Seo.Pattern.validate!()

    seo_description_pattern =
      opts |> Keyword.get(:seo_description_pattern) |> KilnCMS.Seo.Pattern.validate!()

    # `published?:` is accepted for backward compatibility but ignored: the
    # `/published` feed (read + route + GraphQL query) is universal since the
    # official client (#300) — every delivery consumer needs a server-side
    # published-only index, not just the blog (#297).
    _ = Keyword.get(opts, :published?, false)

    # Derive the per-type names from `type` by the project's naming convention.
    resource = __CALLER__.module
    related_name = :"related_#{type}s"
    related_arg = :"related_#{type}_ids"

    # The mergeable relationships, as {complete-set argument, relationship}
    # (#639). One list drives the arguments, the manage_relationship changes,
    # `NormalizeManagedArguments` and `MergeArguments` on both `:update` and
    # `:autosave` — eight hand-written blocks before, where a relationship added
    # to one and missed in another is a silent asymmetry between explicit Save
    # and autosave rather than a compile error.
    mergeable = [{:tag_ids, :tags}, {related_arg, related_name}]

    # `tag_ids` → `add_tag_ids` / `remove_tag_ids`. Derived, not spelled, so the
    # verbs cannot drift from the argument they merge against.
    merge_verbs = fn complete -> {:"add_#{complete}", :"remove_#{complete}"} end

    # Every argument name the merge machinery owns, in declaration order.
    merge_arg_names =
      Enum.flat_map(mergeable, fn {complete, _rel} ->
        {add, remove} = merge_verbs.(complete)
        [complete, add, remove]
      end)

    # The argument trio and the three `manage_relationship` changes for one
    # relationship. Emitted per action rather than shared, because an action's
    # changes are its own.
    #
    # Non-destructive merge verbs (#521 for tags, #637 for the related array).
    # The complete-set argument is exactly that — a whole set — so a
    # partial-update caller (REST/GraphQL/MCP) that only knows the one link it
    # cares about detaches every other by omission. The verbs merge against the
    # current links instead: `add_*` relates what is listed and leaves the rest
    # alone, `remove_*` unrelates what is listed and is a no-op for ids that
    # aren't attached (so it stays idempotent). Combining a complete-set
    # argument with its verbs is refused outright by `MergeArguments` rather
    # than resolved by declaration order.
    merge_arguments = fn ->
      for {complete, _rel} <- mergeable do
        {add, remove} = merge_verbs.(complete)

        quote do
          argument unquote(complete), {:array, :uuid}
          argument unquote(add), {:array, :uuid}
          argument unquote(remove), {:array, :uuid}
        end
      end
    end

    merge_changes = fn ->
      for {complete, relationship} <- mergeable do
        {add, remove} = merge_verbs.(complete)

        quote do
          change manage_relationship(unquote(complete), unquote(relationship),
                   type: :append_and_remove
                 )

          change manage_relationship(unquote(add), unquote(relationship), type: :append)

          # Not `type: :remove`, whose `on_no_match: :error` would turn removing
          # an already-detached link into a failure; the rest are Ash defaults,
          # spelled out because idempotency is the documented contract here.
          change manage_relationship(unquote(remove), unquote(relationship),
                   on_lookup: :ignore,
                   on_match: :unrelate,
                   on_no_match: :ignore,
                   on_missing: :ignore
                 )
        end
      end
    end

    # `:create`'s half of the same list: the complete-set argument and its
    # `manage_relationship`, with no verbs — a create has no existing links to
    # merge against, so the complete set is unambiguously the whole set (#521).
    #
    # Driven off `mergeable` all the same (#639). Hand-writing it left a second
    # source of truth: a relationship added to the list gained the argument on
    # `:update` and `:autosave` and silently did not on `:create`, so a headless
    # create passing it failed with `NoSuchInput` while the equivalent update
    # succeeded — the same drift class, one action over.
    create_merge_arguments = fn ->
      for {complete, _rel} <- mergeable do
        quote do
          argument unquote(complete), {:array, :uuid}
        end
      end
    end

    create_merge_changes = fn ->
      for {complete, relationship} <- mergeable do
        quote do
          change manage_relationship(unquote(complete), unquote(relationship),
                   type: :append_and_remove
                 )
        end
      end
    end

    normalize_create_merge_arguments =
      quote do
        change {KilnCMS.CMS.Changes.NormalizeManagedArguments,
                arguments: unquote(Enum.map(mergeable, &elem(&1, 0)))}
      end

    merge_validations = fn ->
      for {complete, _rel} <- mergeable do
        {add, remove} = merge_verbs.(complete)

        quote do
          validate {KilnCMS.CMS.Validations.MergeArguments,
                    complete: unquote(complete), add: unquote(add), remove: unquote(remove)}
        end
      end
    end

    # Must precede every `manage_relationship`: those changes read the argument
    # at change-time and snapshot it onto the changeset, so a later
    # `set_argument` would normalize nothing.
    normalize_merge_arguments =
      quote do
        change {KilnCMS.CMS.Changes.NormalizeManagedArguments,
                arguments: unquote(merge_arg_names)}
      end

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
      [:title, :slug, :path_alias] ++
        if(excerpt?, do: [:excerpt], else: []) ++
        if(dynamic?, do: [:type_definition_id], else: []) ++
        [
          :blocks,
          :seo_title,
          :seo_description,
          :seo_keywords,
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
          attribute :excerpt, :string,
            public?: true,
            constraints: [max_length: KilnCMS.Limits.paragraph()]
        end
      end

    published_read =
      quote do
        # Public delivery: published content, newest first. Universal (#300):
        # every type — not just the blog — needs a server-side published-only
        # index a keyed delivery caller can't widen to drafts (#297).
        #
        # `state` only, and NOT the fuller "anonymous can read this" rule the
        # search twins pin (#1013). An index is a discovery surface, and gated
        # metadata is public here by deliberate design: `blog_index/2` reads
        # this action with `authorize?: false` and renders an audience-gated
        # post with a "Members" badge rather than hiding it, so its title and
        # excerpt are already public to an anonymous visitor. Narrowing this to
        # `audience == :public` would take the paywall teaser off the blog
        # index. `blocks` is not a public attribute on any read action, so no
        # body rides along either way.
        read :published do
          # Published, any audience, but never passphrase-locked (#1032).
          #
          # The audience axis is deliberately open here: `blog_index/2` reads
          # this with `authorize?: false` and renders a `:member` post with a
          # "Members" badge, because gated metadata is a *marketing* surface —
          # you want a reader to see that members-only content exists.
          #
          # A passphrase is not that. It is a shared secret handed to specific
          # people, and `docs/api.md` says a locked document is "absent from
          # every discovery surface … the only way to reach it is to know its
          # URL *and* its passphrase" — which listing its title, excerpt and
          # link in the index plainly defeats.
          #
          # It is a FILTER rather than a policy clause because the policy that
          # sweeps locked content out of the sitemap, feeds, `llms.txt`, search
          # and ActivityPub only fires for readers who fail
          # `ReadableContentType`, i.e. anonymous ones — and this action's own
          # caller passes `authorize?: false`, so no policy runs at all. #496
          # already needed four per-path guards for exactly this reason; the
          # index was a fifth path nobody had counted.
          filter expr(^ref(:state) == :published and is_nil(^ref(:access_password_hash)))

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
              # `hide_inputs [:audiences, :unlocks]` is a SECURITY control, not
              # tidiness:
              # AshGraphql auto-exposes public action arguments, so without it an
              # anonymous client could send
              # `entryBySlug(audiences: [MEMBER]) { blocks }` and walk straight
              # through the paywall. An argument absent from the schema is
              # rejected at Absinthe validation — strictly stronger than a policy.
              # (The argument cannot be `public? false` instead: `cast_params`
              # gates on `public?`, so a private argument can't be passed through
              # a code interface at all.)
              get :entry_by_slug, :public_by_slug do
                identity false
                hide_inputs [:audiences, :unlocks]
              end

              list :entry_translations, :published_translations do
                hide_inputs [:audiences, :unlocks]
              end

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

            # Write surface (#330) — one generic set over the shared entry tier.
            # `create_entry` needs a `type_definition_id`. Same policy stack as
            # the compiled types; `hide_inputs: [:blocks]` as above.
            mutations do
              create :create_entry, :create, hide_inputs: [:blocks]
              update :update_entry, :update, hide_inputs: [:blocks]
              update :submit_entry_for_review, :submit_for_review, hide_inputs: [:blocks]
              # The return half of the approve/return pair (#626). Admin-only via
              # `policy action(:return_to_draft)`, exactly like `publish_entry` —
              # routing it grants nobody anything the web editor didn't already.
              update :return_entry_to_draft, :return_to_draft, hide_inputs: [:blocks]
              update :publish_entry, :publish, hide_inputs: [:blocks]
              update :unpublish_entry, :unpublish, hide_inputs: [:blocks]
              destroy :delete_entry, :destroy, hide_inputs: [:blocks]
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

              # Write surface (#330) — the shared entry tier, same policy stack
              # as the compiled types. `create` requires `type_definition_id`
              # (discover types via `/api/json/type-definitions` or MCP's
              # `read_type_definitions`). See docs/json-api.md → "Writing".
              post :create
              patch :update
              patch :submit_for_review, route: "/:id/submit-for-review"
              # The return half of the approve/return pair (#626): without it a
              # headless reviewer can approve but has to switch to the web editor
              # to send anything back. Admin-only, like `publish` below.
              patch :return_to_draft, route: "/:id/return-to-draft"
              patch :publish, route: "/:id/publish"
              patch :unpublish, route: "/:id/unpublish"
              delete :destroy
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
              # `hide_inputs [:audiences, :unlocks]` — see the dynamic tier: both
              # delivery-widening arguments must stay off the GraphQL schema, or
              # an anonymous client could ask for gated (or passphrase-locked,
              # #496) content directly. `unlocks` takes fingerprints that are
              # never rendered anywhere, so this is defence in depth rather than
              # a live hole — but it is the same class of hole the `audiences`
              # control was built for, and a new delivery argument that skips it
              # is exactly how the next one gets missed.
              get unquote(:"#{type}_by_slug"), :public_by_slug do
                identity false
                hide_inputs [:audiences, :unlocks]
              end

              list unquote(:"#{type}_translations"), :published_translations do
                hide_inputs [:audiences, :unlocks]
              end

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

            # Write surface (#330 — reverses D7). GraphQL mutations mirror the
            # JSON:API write routes and share the identical policy stack: a
            # read-only API key is forbidden every write; a `:read_write` key
            # acts as its owning user (create/update/submit as editor, publish as
            # admin). `hide_inputs: [:blocks]` keeps the non-public `blocks` union
            # out of every mutation input (AshGraphql can't build an input type
            # for it); body content goes through the public `block_tree` argument.
            mutations do
              create unquote(:"create_#{type}"), :create, hide_inputs: [:blocks]
              update unquote(:"update_#{type}"), :update, hide_inputs: [:blocks]

              update unquote(:"submit_#{type}_for_review"), :submit_for_review,
                hide_inputs: [:blocks]

              # The return half of the approve/return pair (#626), so a review
              # client can reject as well as approve. Admin-only via
              # `policy action(:return_to_draft)`, like `publish_#{type}`.
              update unquote(:"return_#{type}_to_draft"), :return_to_draft, hide_inputs: [:blocks]

              update unquote(:"publish_#{type}"), :publish, hide_inputs: [:blocks]
              update unquote(:"unpublish_#{type}"), :unpublish, hide_inputs: [:blocks]
              # Reversible soft-delete; hard `:purge` is never exposed.
              destroy unquote(:"delete_#{type}"), :destroy, hide_inputs: [:blocks]
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

              # Write surface (#330 — reverses D7 for authenticated writers).
              # Same policy stack as `/mcp`: a read-only API key is forbidden
              # every write by the resource policies; a `:read_write` key acts as
              # its owning user (create/update/submit as an editor; publish as an
              # admin). Anonymous/JWT writers are governed by role alone. Body
              # content is written via the public `block_tree` argument (the raw
              # `blocks` union isn't exposed). See docs/json-api.md → "Writing".
              post :create
              patch :update
              patch :submit_for_review, route: "/:id/submit-for-review"
              # The return half of the approve/return pair (#626): without it a
              # headless reviewer can approve but has to switch to the web editor
              # to send anything back. Admin-only, like `publish` below.
              patch :return_to_draft, route: "/:id/return-to-draft"
              patch :publish, route: "/:id/publish"
              patch :unpublish, route: "/:id/unpublish"
              # DELETE is a reversible soft-delete (AshArchival); hard `:purge`
              # is deliberately never routed and is API-key-banned.
              delete :destroy
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
    # Paywall-safe projection (#337 Phase 2). Deliberately WITHOUT `:blocks`: the
    # teaser read exists to describe a document the caller may not read, so the
    # block tree must never be fetched for it. `Ash.Query.select/2` replaces
    # rather than merges and preparations run after caller query-building, so a
    # caller's `ensure_selected(:blocks)` cannot widen this.
    teaser_fields =
      [
        :id,
        :org_id,
        :title,
        :slug,
        :locale,
        :audience,
        :state,
        :seo_title,
        :seo_description,
        :seo_image,
        :canonical_url,
        # `path_alias` so the canonical redirect still works on a teaser.
        :path_alias,
        :published_at,
        :updated_at
      ] ++
        if(excerpt?, do: [:excerpt], else: []) ++
        if(dynamic?, do: [:type_definition_id], else: [])

    # The locked-page projection (#496): everything the teaser carries, plus the
    # stored hash the unlock endpoint verifies against and the fingerprint it
    # mints a grant from. Still WITHOUT `:blocks` — a lock page describes a
    # document it is refusing to serve, so the body must not be fetched for it.
    locked_fields = teaser_fields ++ [:access_password_hash, :password_fingerprint]

    public_reads =
      if dynamic? do
        quote do
          read :public_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false
            argument :type_definition_id, :uuid, allow_nil?: false

            # Audiences the CALLER has already established the reader holds.
            # Defaults to `[]`, so every existing caller is bit-identical:
            # `:public` only. HIDDEN from GraphQL (`hide_inputs` on the query),
            # or an anonymous client could ask for gated content directly.
            argument :audiences, {:array, :atom},
              default: [],
              constraints: [items: [one_of: KilnCMS.CMS.Audiences.all()]]

            # Unlock grants (#496) this request carries — fingerprints of
            # passphrases the caller has already proved, never a raw passphrase
            # and never client-authored: the controller only ever passes values
            # it read out of a signed cookie or a signed token.
            #
            # Matching the fingerprint HERE rather than in the controller is the
            # point: rotating the passphrase changes the hash, which changes the
            # fingerprint, so every outstanding grant stops selecting the row at
            # the moment of rotation. Default `[]` keeps every existing caller
            # locked out of locked content, which is the safe direction.
            argument :unlocks, {:array, :string}, default: []

            filter expr(
                     ^ref(:state) == :published and
                       (^ref(:audience) == :public or ^ref(:audience) in ^arg(:audiences)) and
                       (is_nil(^ref(:access_password_hash)) or
                          ^ref(:password_fingerprint) in ^arg(:unlocks)) and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale) and
                       ^ref(:type_definition_id) == ^arg(:type_definition_id)
                   )
          end

          read :published_translations do
            argument :slug, :string, allow_nil?: false
            argument :type_definition_id, :uuid, allow_nil?: false

            argument :audiences, {:array, :atom},
              default: [],
              constraints: [items: [one_of: KilnCMS.CMS.Audiences.all()]]

            # Unlock grants (#496) this request carries — fingerprints of
            # passphrases the caller has already proved, never a raw passphrase
            # and never client-authored: the controller only ever passes values
            # it read out of a signed cookie or a signed token.
            #
            # Matching the fingerprint HERE rather than in the controller is the
            # point: rotating the passphrase changes the hash, which changes the
            # fingerprint, so every outstanding grant stops selecting the row at
            # the moment of rotation. Default `[]` keeps every existing caller
            # locked out of locked content, which is the safe direction.
            argument :unlocks, {:array, :string}, default: []

            filter expr(
                     ^ref(:state) == :published and
                       (^ref(:audience) == :public or ^ref(:audience) in ^arg(:audiences)) and
                       (is_nil(^ref(:access_password_hash)) or
                          ^ref(:password_fingerprint) in ^arg(:unlocks)) and
                       ^ref(:slug) == ^arg(:slug) and
                       ^ref(:type_definition_id) == ^arg(:type_definition_id)
                   )
          end

          read :teaser_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false
            argument :type_definition_id, :uuid, allow_nil?: false

            # Requires a NON-public audience, so this action can never stand in
            # for `:public_by_slug` — and never returns a row a plain visitor was
            # already entitled to see.
            filter expr(
                     ^ref(:state) == :published and ^ref(:audience) != :public and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale) and
                       ^ref(:type_definition_id) == ^arg(:type_definition_id)
                   )

            prepare build(select: unquote(teaser_fields))
          end

          # Locate a LOCKED published document (#496) in order to render its
          # passphrase form, or to verify a submitted passphrase.
          #
          # It takes `:audiences` for a reason that is easy to miss: the lock is
          # ANDed with the audience axis, so this read must only match a document
          # the reader would otherwise be entitled to. Without that clause a
          # locked members-only post would prompt an anonymous visitor for a
          # passphrase that, once entered, still left them at the paywall — and
          # the delivery funnel tries the lock page before the paywall, so the
          # paywall would never render at all. Consumed with
          # `authorize?: false` like the other delivery reads, so this filter is
          # the sole boundary — note it *requires* a passphrase to be set, so it
          # can never stand in for `:public_by_slug` and never returns a row an
          # unlocked visitor was already entitled to read.
          #
          # The projection is the teaser's (no `:blocks`) plus the hash: the
          # whole point of a lock page is to describe a document without
          # serving it.
          read :locked_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false
            argument :type_definition_id, :uuid, allow_nil?: false

            argument :audiences, {:array, :atom},
              default: [],
              constraints: [items: [one_of: KilnCMS.CMS.Audiences.all()]]

            filter expr(
                     ^ref(:state) == :published and
                       (^ref(:audience) == :public or ^ref(:audience) in ^arg(:audiences)) and
                       not is_nil(^ref(:access_password_hash)) and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale) and
                       ^ref(:type_definition_id) == ^arg(:type_definition_id)
                   )

            prepare build(select: unquote(locked_fields))
          end
        end
      else
        quote do
          read :public_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false

            # See the dynamic tier above: default `[]` keeps every existing
            # caller unchanged, and the argument is hidden from GraphQL.
            argument :audiences, {:array, :atom},
              default: [],
              constraints: [items: [one_of: KilnCMS.CMS.Audiences.all()]]

            # Unlock grants (#496) this request carries — fingerprints of
            # passphrases the caller has already proved, never a raw passphrase
            # and never client-authored: the controller only ever passes values
            # it read out of a signed cookie or a signed token.
            #
            # Matching the fingerprint HERE rather than in the controller is the
            # point: rotating the passphrase changes the hash, which changes the
            # fingerprint, so every outstanding grant stops selecting the row at
            # the moment of rotation. Default `[]` keeps every existing caller
            # locked out of locked content, which is the safe direction.
            argument :unlocks, {:array, :string}, default: []

            filter expr(
                     ^ref(:state) == :published and
                       (^ref(:audience) == :public or ^ref(:audience) in ^arg(:audiences)) and
                       (is_nil(^ref(:access_password_hash)) or
                          ^ref(:password_fingerprint) in ^arg(:unlocks)) and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale)
                   )
          end

          # Every published locale variant of a slug, for hreflang alternates
          # and the language switcher.
          read :published_translations do
            argument :slug, :string, allow_nil?: false

            argument :audiences, {:array, :atom},
              default: [],
              constraints: [items: [one_of: KilnCMS.CMS.Audiences.all()]]

            # Unlock grants (#496) this request carries — fingerprints of
            # passphrases the caller has already proved, never a raw passphrase
            # and never client-authored: the controller only ever passes values
            # it read out of a signed cookie or a signed token.
            #
            # Matching the fingerprint HERE rather than in the controller is the
            # point: rotating the passphrase changes the hash, which changes the
            # fingerprint, so every outstanding grant stops selecting the row at
            # the moment of rotation. Default `[]` keeps every existing caller
            # locked out of locked content, which is the safe direction.
            argument :unlocks, {:array, :string}, default: []

            filter expr(
                     ^ref(:state) == :published and
                       (^ref(:audience) == :public or ^ref(:audience) in ^arg(:audiences)) and
                       (is_nil(^ref(:access_password_hash)) or
                          ^ref(:password_fingerprint) in ^arg(:unlocks)) and
                       ^ref(:slug) == ^arg(:slug)
                   )
          end

          # Locate a GATED published document in order to render a paywall for a
          # reader who may not read it. Consumed with `authorize?: false` like the
          # other delivery reads, so this filter is the sole boundary — note it
          # *requires* a non-public audience and never selects `:blocks`.
          read :teaser_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false

            filter expr(
                     ^ref(:state) == :published and ^ref(:audience) != :public and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale)
                   )

            prepare build(select: unquote(teaser_fields))
          end

          # Locate a LOCKED published document (#496) — see the dynamic tier
          # above for why the filter requires a passphrase and the projection
          # excludes the block tree.
          read :locked_by_slug do
            get? true
            argument :slug, :string, allow_nil?: false
            argument :locale, :string, allow_nil?: false

            argument :audiences, {:array, :atom},
              default: [],
              constraints: [items: [one_of: KilnCMS.CMS.Audiences.all()]]

            filter expr(
                     ^ref(:state) == :published and
                       (^ref(:audience) == :public or ^ref(:audience) in ^arg(:audiences)) and
                       not is_nil(^ref(:access_password_hash)) and
                       ^ref(:slug) == ^arg(:slug) and ^ref(:locale) == ^arg(:locale)
                   )

            prepare build(select: unquote(locked_fields))
          end
        end
      end

    # Headless search reads, generated in pairs (#297): keyword search,
    # semantic search, and autocomplete each ship a `*_published` delivery
    # twin whose `state == :published` filter is pinned **server-side** — the
    # search counterpart of the plain index vs `:published`. The read policy
    # alone doesn't protect delivery consumers here: a bearer API key
    # authorizes as the account that minted it, so with an editor/admin key
    # the base actions silently match drafts — and, until #1013, gated and
    # locked rows too. The twins cannot be widened by any credential, and they
    # drop the `state` facet argument (dead weight against the pinned filter).
    # Both flavors come from one template so their query surfaces can't drift.
    join_and = fn clauses ->
      Enum.reduce(clauses, fn clause, acc -> quote(do: unquote(acc) and unquote(clause)) end)
    end

    # The pinned filter is the whole "an anonymous visitor could read this" rule,
    # not just `state` (#1013). It used to pin state alone, which made the twins
    # exactly as leaky as the base actions for the caller they exist to protect:
    # an API key authorizes as the account that minted it, the `OrgAdmin` bypass
    # above authorizes that account for everything, and the twins then returned
    # audience-gated and passphrase-locked rows to a front end holding a
    # delivery key. `docs/api.md` already promised the opposite for locked
    # documents ("absent from every discovery surface … keyword and semantic
    # search").
    #
    # What leaked here is metadata — title, slug, excerpt, SEO — since `blocks`
    # is not a public attribute on any read action. `GET /api/search` was the
    # one that leaked body text, through its `highlight` calc over
    # `search_text`; that endpoint is now actorless (#1013).
    #
    # Deliberately the same three clauses as
    # `KilnCMS.CMS.Audiences.public_to_anonymous?/1` (#1006) — that function is
    # the in-memory statement of this rule; these are the SQL one, and the two
    # cannot share code. If one changes, change the other.
    pinned_state =
      quote do
        ^ref(:state) == :published and ^ref(:audience) == :public and
          is_nil(^ref(:access_password_hash))
      end

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

          # The schema.org @type of this type's fired :json_ld main node
          # (#357, GEO). Dynamic entries carry theirs on the TypeDefinition
          # row instead, so the entry tier has no marker.
          def __kiln_schema_org_type__, do: unquote(schema_org_type)

          # Optional pathauto slug pattern (#454); nil = default derivation.
          # Dynamic entries carry theirs on the TypeDefinition row.
          def __kiln_content_slug_pattern__, do: unquote(slug_pattern)

          # Optional pathauto alias pattern (#485); nil = no auto alias.
          def __kiln_content_alias_pattern__, do: unquote(alias_pattern)

          # Optional default SEO patterns (#805); nil = the record's own
          # fields. Dynamic entries carry theirs on the TypeDefinition row.
          def __kiln_seo_title_pattern__, do: unquote(seo_title_pattern)

          def __kiln_seo_description_pattern__, do: unquote(seo_description_pattern)
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

      # Multi-tenancy (epic #336): every content row is partitioned by its
      # owning organization via an `org_id` column (Ash `:attribute` strategy —
      # chosen over schema-per-tenant so the single pgvector HNSW / trigram
      # indexes and the one Meilisearch index aren't multiplied per site).
      # `global?: true` keeps a tenant OPTIONAL for now: existing tenant-less
      # code paths (editor, seeds, anonymous headless delivery) keep working and
      # land in the default org (see the `org_id` attribute default). The
      # delivery reads run `authorize?: false`, so once a second org exists the
      # tenant MUST be threaded onto every such read (a later stacked PR) — until
      # then the single default org makes tenant-less reads safe.
      multitenancy do
        strategy :attribute
        attribute :org_id
        global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
      end

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
        show_calculations [:published, :word_count, :reading_time_minutes]

        form do
          field :seo_description, type: :long_text
          field :canonical_url, type: :short_text
        end
      end

      paper_trail do
        change_tracking_mode(:changes_only)
        store_action_name?(true)
        # The generated `*.Version` resource inherits this resource's `:attribute`
        # multitenancy (epic #336), so its table needs the tenant column as a real
        # attribute rather than buried in the freeform `changes` map — otherwise
        # version creation (in the same transaction as the source write) has no
        # `org_id` to satisfy the inherited multitenancy. The version inherits
        # `global?: true` too, so tenant-less writes still work.
        attributes_as_attributes([:org_id])
        # `access_password_hash`/`password_fingerprint` are ignored (#496) so a
        # bcrypt hash never lands in version history, where it would outlive
        # every rotation and be readable by anyone who can read versions.
        #
        # `next_occurrence_at` is ignored (#766) for the reason `embedding` is:
        # it is derived from `custom_fields`, which IS versioned, so a version
        # carrying it would show a redundant field in every diff of an event —
        # and one that moves on its own, since the sweep advances it without any
        # editorial change at all.
        ignore_attributes([
          :inserted_at,
          :updated_at,
          :embedding,
          :embedded_at,
          :next_occurrence_at,
          :lock_version,
          :access_password_hash,
          :password_fingerprint
        ])

        # Background embedding writes aren't editorial changes — keep the
        # `:set_embedding` action out of the version history.
        ignore_actions([
          :set_embedding,
          :set_published_version_id,
          :set_oembed_metadata,
          :set_next_occurrence,
          :backdate_published_at,
          :reassign_author,
          :reindex_search_text
        ])

        # No FK from version -> source, so a `:purge` can hard-delete a record
        # whose history exists. Versions of purged content are kept as audit rows.
        reference_source?(false)
        # "Who" on each version (#352): the acting user, when the write carried
        # one. Nilify on user deletion — the audit row must outlive the account.
        belongs_to_actor(:user, KilnCMS.Accounts.User,
          domain: KilnCMS.Accounts,
          on_delete: :nilify
        )

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
        # Multi-tenancy (epic #336): the scheduler's `where` scan runs globally
        # (each org scanned explicitly via list_tenants under strict tenancy) and
        # see every org's due records), while each worker action re-runs under the
        # record's own `org_id` tenant — so a scheduled publish/unpublish/purge/
        # sweep fires each record into the right site. AshOban also auto-partitions
        # the per-record job unique keys by tenant.
        use_tenant_from_record? true

        triggers do
          trigger :publish_scheduled do
            action :publish_scheduled
            queue :scheduling
            scheduler_cron "* * * * *"
            # Strict-tenancy prep (#419): schedulers scan per org, not globally.
            list_tenants KilnCMS.Accounts.ListOrgIds

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
            # Strict-tenancy prep (#419): schedulers scan per org, not globally.
            list_tenants KilnCMS.Accounts.ListOrgIds

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
            # Strict-tenancy prep (#419): schedulers scan per org, not globally.
            list_tenants KilnCMS.Accounts.ListOrgIds

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
            # Strict-tenancy prep (#419): schedulers scan per org, not globally.
            list_tenants KilnCMS.Accounts.ListOrgIds

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
          # Delivery lookup for multi-segment path aliases (#485) — hit on the
          # URL-miss fallback, so it must seek. Partial: most rows have none.
          index [:path_alias],
            name: unquote("#{table}_path_alias_index"),
            where: "path_alias IS NOT NULL",
            all_tenants?: true

          # HNSW index for approximate nearest-neighbour search over embeddings,
          # using cosine distance (`<=>`). The `embedding vector_cosine_ops`
          # column string carries the opclass through to the generated DDL.
          # `all_tenants?: true` keeps `org_id` OUT of the index (epic #336):
          # pgvector HNSW indexes cannot be multicolumn, so the tenant filter
          # rides the query's `WHERE org_id = ?` instead (a post-filter over the
          # shared ANN graph — the reason `:attribute` beats schema-per-tenant).
          index ["embedding vector_cosine_ops"],
            name: unquote("#{table}_embedding_hnsw_index"),
            using: "hnsw",
            all_tenants?: true

          # Trigram GIN index on title for typo-tolerant autocomplete (the `%`
          # similarity operator + `similarity(...)`). `gin_trgm_ops` opclass is
          # carried through via the column string. `all_tenants?: true` keeps it
          # single-column too (a multicolumn GIN over a plain uuid column would
          # need `btree_gin`); the tenant filter rides the query.
          index ["title gin_trgm_ops"],
            name: unquote("#{table}_title_trgm_index"),
            using: "gin",
            all_tenants?: true

          # Point-lookup index for the delivery hot path (`public_by_slug`).
          # `:unique_slug` is now the `org_id`-LEADING `(org_id, slug, locale)`
          # composite, which Postgres can't seek for a tenant-less delivery read
          # (PR1 reads set no tenant under `global?: true`). `all_tenants?: true`
          # keeps this one `org_id`-free so `(slug, locale)` lookups seek again;
          # once the delivery path threads the tenant (a later PR) it becomes
          # redundant with the composite and can be dropped.
          index [:slug, :locale],
            name: unquote("#{table}_slug_locale_lookup_index"),
            all_tenants?: true

          # The "what's on" delivery index (#766): `WHERE org_id = ? AND
          # next_occurrence_at >= ?` ordered ascending. Codegen prepends the
          # tenant column on a multitenant resource, so the created index is
          # `(org_id, next_occurrence_at)` — which is exactly the seek this
          # needs, leading column equality then a range on the sort key.
          #
          # ASCENDING is the point. A btree IS ascending-nulls-last, so this
          # ordering is servable by a plain index; `DESC NULLS LAST` is servable
          # by none (see the repo's Postgres notes), and it would have needed an
          # expression index of its own. "Soonest first" is ascending, and the
          # window's lower bound drops the NULL rows before ordering ever comes
          # up, so the sort has no nulls to place.
          #
          # Partial, because nearly every row is NULL: a site with one event
          # type and forty thousand pages indexes the events, not the pages.
          index [:next_occurrence_at],
            name: unquote("#{table}_next_occurrence_index"),
            where: "next_occurrence_at IS NOT NULL"
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
        # change can run. `DeleteArtifacts` purges any fired artifacts so a
        # soft-deleted (archived) record can't keep being served from the
        # artifact cache/table — matters now that soft-delete is reachable over
        # the headless write API (#330), not just admin-only from LiveView.
        destroy :destroy do
          primary? true
          require_atomic? false
          change KilnCMS.CMS.Changes.DeleteArtifacts
        end

        create :create do
          primary? true
          # A blank/omitted slug is derived from the title (stop words
          # stripped), so a title alone is enough to create content.
          change KilnCMS.CMS.Changes.DeriveSlug
          change KilnCMS.CMS.Changes.DeriveAlias
          # Stamp the acting user as the author (system/seed creates leave nil).
          change relate_actor(:author, allow_nil?: true)
          # Set the many-to-many links from lists of ids (nil/omitted = no change).
          # No merge verbs here: a create has no existing links to merge against,
          # so `tag_ids` is unambiguously the whole set (#521).
          unquote_splicing(create_merge_arguments.())
          unquote(normalize_create_merge_arguments)
          unquote_splicing(create_merge_changes.())

          # Headless block-body writes (#330): the `blocks` union isn't public on
          # the auto API, so accept the body as a public array of block maps and
          # cast it into the union (sanitized on cast). Omitted = empty body.
          argument :block_tree, {:array, :map}
          change KilnCMS.CMS.Changes.ApplyBlocksInput
          change KilnCMS.CMS.Changes.ApplyCustomFields
          # AFTER `ApplyCustomFields`: the schedule this reads is the coerced
          # value that changeset writes, not the editor's raw parts (#766).
          change KilnCMS.CMS.Changes.SetNextOccurrence
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.EnqueueOEmbed

          # Shared-passphrase lock (#496). Two arguments rather than one because
          # blank must mean "unchanged", not "clear" — see
          # `Changes.ApplyAccessPassword`. `access_password` is sensitive so it
          # never shows up in a logged changeset.
          argument :access_password, :string, sensitive?: true
          argument :remove_access_password, :boolean, default: false
          change KilnCMS.CMS.Changes.ApplyAccessPassword

          validate KilnCMS.CMS.Validations.SlugAvailable
          validate KilnCMS.CMS.Validations.PathAliasValid
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
          # Clearing the slug regenerates it from the title — see `:create`.
          change KilnCMS.CMS.Changes.DeriveSlug
          change KilnCMS.CMS.Changes.DeriveAlias
          # Renaming a published slug leaves a 301 behind at the old URL.
          change KilnCMS.CMS.Changes.RecordSlugRedirect
          unquote_splicing(merge_arguments.())
          unquote(normalize_merge_arguments)
          unquote_splicing(merge_changes.())

          # Headless block-body writes (#330) — see `:create`. Omitted argument
          # leaves the existing body untouched (a metadata-only PATCH is safe).
          argument :block_tree, {:array, :map}
          change KilnCMS.CMS.Changes.ApplyBlocksInput
          change KilnCMS.CMS.Changes.ApplyCustomFields
          # AFTER `ApplyCustomFields` — see `:create` (#766).
          change KilnCMS.CMS.Changes.SetNextOccurrence
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.EnqueueOEmbed

          # Shared-passphrase lock (#496). Two arguments rather than one because
          # blank must mean "unchanged", not "clear" — see
          # `Changes.ApplyAccessPassword`. `access_password` is sensitive so it
          # never shows up in a logged changeset.
          argument :access_password, :string, sensitive?: true
          argument :remove_access_password, :boolean, default: false
          change KilnCMS.CMS.Changes.ApplyAccessPassword

          # Edits to already-published content fire a `<type>.updated` webhook;
          # `only_when: :published` keeps draft edits and autosaves silent.
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "updated", only_when: :published}

          # Re-fire when editing already-live content (#330). Firing is otherwise
          # bound to `:publish`; an in-place edit of a published record (headless
          # write-through, in-context editing) would leave the fired artifact
          # stale. `only_when: :published` keeps draft edits/autosaves silent.
          change {KilnCMS.CMS.Changes.FireArtifacts, only_when: :published}

          unquote_splicing(merge_validations.())

          validate KilnCMS.CMS.Validations.SlugAvailable
          validate KilnCMS.CMS.Validations.PathAliasValid
          validate KilnCMS.CMS.Validations.SeoUrls
          validate KilnCMS.CMS.Validations.ScheduleOrder

          # The alt-text gate is on publish (#403), but `:update` re-fires
          # artifacts for an already-published record — so editing a live page
          # to show an alt-less image bypassed the gate entirely (#722). Re-run
          # it here, but only when it can matter: the record is (still)
          # published, and the body is in the params at all — a metadata-only
          # PATCH, and every draft edit, stays untouched. `only_new: true` scopes
          # it to images this edit newly leaves undescribed, so a page that
          # already carried one (published before the gate) stays editable.
          # Autosave is deliberately exempt (a draft in progress is not an
          # assertion the page is done).
          validate {KilnCMS.CMS.Validations.MediaAltText, only_new: true},
            where: [changing(:blocks), attribute_equals(:state, :published)]

          # Same reasoning for the claim gate (#377): `:update` re-fires
          # artifacts for a live record, so editing a published page to add a
          # flagged claim would ship it without ever passing `:publish`.
          # `only_new: true` scopes it to claims this edit introduces, so
          # switching the gate on doesn't make every page that already carried
          # one un-editable.
          #
          # No `changing(...)` guard, unlike the alt-text gate above. That one
          # can key on `:blocks` because blocks are the only thing it reads;
          # this also reads the title and SEO fields, since a claim in the meta
          # description ships to a search results page. `where:` is an AND, so
          # there is no "any of these four changed" to express — and it would
          # buy nothing: an update that touched none of them diffs to zero new
          # offenders and passes anyway. The gate is opt-in, so the scan it
          # costs is one an operator asked for.
          validate {KilnCMS.CMS.Validations.ComplianceClaims, only_new: true},
            where: [attribute_equals(:state, :published)]
        end

        # Debounced draft autosave from the editor. Writes the same content as
        # `:update`, but as a distinct action so its PaperTrail versions are
        # tagged `version_action_name: :autosave` and can be coalesced — a save
        # per editor pause would otherwise flood history (issue #32).
        # `CoalesceAutosaveVersions` collapses the trailing run of autosave
        # versions into a single snapshot after each save — except for rows an
        # anchor has already committed to, which are immutable, so with
        # `audit_anchor_every_write` on nothing is collapsed at all (#671).
        # Drafts only, and enforced HERE rather than only in the editor (#1015).
        # It used to be a LiveView invariant — `perform_autosave/1` bails unless
        # `draft?(socket)` — which is not the same as the action refusing. This
        # action inherits `default_accept`, so it can write `audience`, and it
        # carries `ApplyAccessPassword` — but it has no `FireArtifacts` and no
        # `NotifyWebhooks`, because a draft edit is silent by design. That
        # combination on a *published* row is the bad one: it would gate or lock
        # a live document while firing nothing, so the artifacts, the feeds and
        # the Meilisearch index (#1006, #496) would all keep serving the
        # ungated version, with nothing anywhere recording that the document
        # had changed.
        #
        # `change filter` and not `validate attribute_equals`: the guard has to
        # be a compare-and-swap on the ROW, the way the workflow transitions
        # below are. A validation reads the struct the editor loaded, so a
        # publish landing between load and write would sail past it — which is
        # exactly the race, not a hypothetical. A miss raises `StaleRecord`,
        # which `ContentEditorLive` already turns into "this content changed
        # elsewhere, reload" (#137).
        update :autosave do
          require_atomic? false
          change filter(expr(^ref(:state) == :draft))
          change optimistic_lock(:lock_version)
          # Clearing the slug regenerates it from the title — see `:create`.
          change KilnCMS.CMS.Changes.DeriveSlug
          change KilnCMS.CMS.Changes.DeriveAlias
          # Mirrors `:update`'s tag arguments (#521). Autosave isn't on any API
          # surface, but `ContentEditorLive.do_autosave/1` feeds this action the
          # params it collected for the `:update` form — so the moment the tag
          # picker grows a merge input, an action that didn't declare it would
          # fail every debounce with `NoSuchInput` while explicit Save kept
          # working. Declaring them keeps the two actions interchangeable.
          unquote_splicing(merge_arguments.())
          unquote(normalize_merge_arguments)
          unquote_splicing(merge_changes.())
          unquote_splicing(merge_validations.())

          change KilnCMS.CMS.Changes.ApplyCustomFields
          # AFTER `ApplyCustomFields` — see `:create` (#766).
          change KilnCMS.CMS.Changes.SetNextOccurrence
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.EnqueueOEmbed

          # Shared-passphrase lock (#496). Two arguments rather than one because
          # blank must mean "unchanged", not "clear" — see
          # `Changes.ApplyAccessPassword`. `access_password` is sensitive so it
          # never shows up in a logged changeset.
          argument :access_password, :string, sensitive?: true
          argument :remove_access_password, :boolean, default: false
          change KilnCMS.CMS.Changes.ApplyAccessPassword

          change KilnCMS.CMS.Changes.CoalesceAutosaveVersions
          validate KilnCMS.CMS.Validations.SlugAvailable
          validate KilnCMS.CMS.Validations.PathAliasValid
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
          # A workflow transition takes no content input, and its UPDATE is a
          # compare-and-swap on the current state — see `:return_to_draft` for the
          # full rationale (#873); this closes the same two gaps on the other three
          # routed transitions (#879).
          accept []
          change filter(expr(^ref(:state) == :draft))
          change transition_state(:in_review)
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "in_review"}
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :submitted_for_review}
        end

        update :return_to_draft do
          require_atomic? false
          # A workflow transition takes no content input. Without this the action
          # inherits `default_accept` (17 attributes), so `PATCH
          # /:id/return-to-draft` with a populated `attributes` object would write
          # content while skipping everything `:update` attaches — the optimistic
          # lock, `SlugAvailable`/`PathAliasValid`/`SeoUrls`, `RecordSlugRedirect`,
          # `SetSearchText`, `EnqueueEmbedding`. `docs/json-api.md` has always said
          # these routes "carry no attributes"; now that is true of this one (#626).
          accept []

          # The state machine checks `changeset.data.state` — the in-memory struct
          # — and the resulting UPDATE carries no state predicate, so two admins
          # acting on an `:in_review` record concurrently can both win. A publish
          # committing first and this landing second would leave `state: :draft`
          # with `published_at`, a published version and live artifacts, which
          # `unpublish` can then never clear because it requires `:published`.
          # Filtering makes the write a real compare-and-swap.
          change filter(expr(^ref(:state) == :in_review))
          change transition_state(:draft)
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "returned_to_draft"}
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :returned_to_draft}
        end

        update :publish do
          require_atomic? false
          # FIRST, so its `before_action` hook registers before the two
          # block-reading validations below defer themselves to the same phase:
          # an open collab session's prose rides in on this write or is lost
          # with the DocServer (#1061), and the gates must judge what actually
          # publishes. No-op when nobody is editing.
          change KilnCMS.CMS.Changes.CheckpointCollabRoom
          # No content input, and a compare-and-swap on state (#879) — see
          # `:return_to_draft`. Without the filter a publish landing after a
          # concurrent transition would stamp `published_at` + artifacts onto a
          # row another writer had already moved out of a publishable state.
          accept []
          # Compliance gate (#356): block publish when a required editorial consent
          # is missing (config-gated, no-op by default — see the validation).
          validate KilnCMS.CMS.Validations.RequiredConsent
          # Accessibility gate (#403), config-gated and off by default: a publish
          # is refused when the document shows an image with neither alt text nor
          # a `decorative` mark.
          validate KilnCMS.CMS.Validations.MediaAltText, before_action?: true
          # Claim gate (#377), config-gated and off by default: a publish is
          # refused when the document carries a phrase an `:error`-severity
          # compliance rule matches. Same rules the editor's compliance panel
          # advises on, so the gate can never disagree with the panel the
          # author has been reading.
          validate KilnCMS.CMS.Validations.ComplianceClaims, before_action?: true
          change filter(expr(^ref(:state) == :draft or ^ref(:state) == :in_review))
          change transition_state(:published)
          change set_attribute(:published_at, &DateTime.utc_now/0)
          # A publish never used to change content, so it carried none of the
          # derived-column changes. It can now (#1061), and a published document
          # that cannot be found by its own published words is a poor answer.
          # After the checkpoint, because hooks run in registration order.
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.RecordPublishedVersion
          change KilnCMS.CMS.Changes.FireArtifacts
          change KilnCMS.CMS.Changes.NotifyWebhooks
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}
          change KilnCMS.CMS.Changes.AutoCompleteTasks
        end

        update :publish_scheduled do
          # Run by the AshOban scheduler once `scheduled_at` has passed.
          require_atomic? false
          # Same room checkpoint as `:publish`, and for the same reason (#1061).
          # "A scheduled publish is never under an open room" is false: schedule
          # for 09:00, keep editing collaboratively, and the cron fires at 09:00
          # into a live room. FIRST, so the gates below see the merged tree.
          change KilnCMS.CMS.Changes.CheckpointCollabRoom
          # Same compliance gate as `:publish` (#356) — a scheduled publish must
          # also satisfy any required consent.
          validate KilnCMS.CMS.Validations.RequiredConsent
          # Accessibility gate (#403), config-gated and off by default: a publish
          # is refused when the document shows an image with neither alt text nor
          # a `decorative` mark.
          validate KilnCMS.CMS.Validations.MediaAltText, before_action?: true
          # Same claim gate as `:publish` (#377) — a scheduled publish is still
          # a publish, and a claim that must not go live at 09:00 by hand must
          # not go live at 09:00 by scheduler either.
          validate KilnCMS.CMS.Validations.ComplianceClaims, before_action?: true
          change transition_state(:published)
          change set_attribute(:published_at, &DateTime.utc_now/0)
          change set_attribute(:scheduled_at, nil)
          # A publish never used to change content, so it carried none of the
          # derived-column changes. It can now (#1061), and a published document
          # that cannot be found by its own published words is a poor answer.
          # After the checkpoint, because hooks run in registration order.
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.RecordPublishedVersion
          change KilnCMS.CMS.Changes.FireArtifacts
          change KilnCMS.CMS.Changes.NotifyWebhooks
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}
          change KilnCMS.CMS.Changes.AutoCompleteTasks
        end

        update :restore_version do
          # Reverts content fields to a previous PaperTrail version (captured as
          # a new version itself). Workflow state is left unchanged.
          require_atomic? false
          accept []
          argument :version_id, :uuid, allow_nil?: false
          change KilnCMS.CMS.Changes.RestoreVersion

          # A restore is a content write, so everything derived from content has
          # to move with it (#691). Declared AFTER `RestoreVersion`, which writes
          # the restored values from a `before_action` hook — hooks run in
          # registration order, so `SetSearchText` sees the reverted document and
          # not the one being replaced.
          change KilnCMS.CMS.Changes.RecordSlugRedirect
          # `next_occurrence_at` is derived from `custom_fields`, and a restore
          # can revert the schedule — so it moves with the rest of the derived
          # values rather than being left pointing at the replaced document's
          # dates (#766, and the same argument #691 made for `search_text`).
          change KilnCMS.CMS.Changes.SetNextOccurrence
          change KilnCMS.CMS.Changes.SetSearchText
          change KilnCMS.CMS.Changes.EnqueueEmbedding
          change KilnCMS.CMS.Changes.EnqueueOEmbed
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "updated", only_when: :published}
          change {KilnCMS.CMS.Changes.FireArtifacts, only_when: :published}
        end

        update :unpublish do
          require_atomic? false
          # No content input, and a compare-and-swap on state (#879) — see
          # `:return_to_draft`.
          accept []
          change filter(expr(^ref(:state) == :published))
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
          # Same no-input + compare-and-swap treatment as the other transitions
          # (#879). `from: [:draft, :in_review, :published]`, so the CAS predicate
          # is "not already archived".
          accept []
          change filter(expr(^ref(:state) != :archived))
          change transition_state(:archived)
          # Archiving a *published* record must tear down its published version and
          # artifacts exactly as `:unpublish` does — otherwise they orphan (no race
          # needed, #879 pt 3). Both are harmless when archiving a draft/in_review
          # record: there are no artifacts to purge, and `ClearPublishedVersion`
          # writes a nil `published_version_id` that was already nil.
          change KilnCMS.CMS.Changes.ClearPublishedVersion
          change KilnCMS.CMS.Changes.DeleteArtifacts
          # Archiving a published record removes it from delivery exactly as
          # `:unpublish` does, so it emits the same event (#914) — a
          # subscriber/CDN watching for content leaving delivery must not care
          # which editor action caused that. `only_when: :was_published`, not
          # `:published`: this action always lands on `:archived`, so a plain
          # `:published` check (the resulting state) would never fire, and
          # archiving a draft/in_review record — which was never delivered —
          # correctly stays silent.
          change {KilnCMS.CMS.Changes.NotifyWebhooks,
                  event: "unpublished", only_when: :was_published}
        end

        # Sends archived content back to draft (the state-machine inverse of
        # :archive).
        #
        # `accept []` + `change filter` for the reasons #626 and #879 gave the
        # other four transitions — this was the fifth and never got them. A
        # workflow transition takes no content input, and without `accept []`
        # this one inherited `default_accept`: all 17 attributes, `:audience`
        # and `:blocks` among them, writable through an action that attaches no
        # `FireArtifacts`, no `NotifyWebhooks`, no `optimistic_lock` and none of
        # the `SlugAvailable`/`SeoUrls`/`ScheduleOrder` validations. It is not
        # routed on JSON:API or GraphQL, but AshAdmin renders every accepted
        # input as a form field, so unarchiving was a way to rewrite a body and
        # an audience while recording nothing.
        update :unarchive do
          require_atomic? false
          accept []
          change filter(expr(^ref(:state) == :archived))
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

          # Trashing is a soft delete: `:destroy` runs `DeleteArtifacts`, which
          # purges the fired artifacts AND enqueues a Meilisearch removal — but
          # it does not change `state`, so a trashed published document is still
          # `:published` underneath. Restoring it therefore puts it straight back
          # on the delivery path with no artifacts and no search entry, and
          # nothing would rebuild them until an unrelated edit re-fired it (#1025).
          #
          # `only_when: :published` because restoring a trashed *draft* has
          # nothing to rebuild — a draft never had artifacts to purge, and firing
          # one would publish an artifact for unpublished content.
          #
          # Deliberately no webhook: trashing emits none either (it is not an
          # unpublish), and a `published` event for a document subscribers were
          # never told had gone would read as a second publish.
          change {KilnCMS.CMS.Changes.FireArtifacts, only_when: :published}
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

        # Internal: restore a publication date an importer carried over (#487).
        #
        # Its own action for the same reason `:set_published_version_id` is.
        # `:publish` stamps `published_at` with `utc_now`, so a bulk importer has
        # to put the source date back afterwards — and doing that through
        # `:update` dragged the whole edit chain along: `NotifyWebhooks` and
        # `FireArtifacts` are both `only_when: :published`, and the record IS
        # published by then, so a 4,000-post import emitted 4,000 spurious
        # `updated` webhooks and re-fired every artifact a second time.
        update :backdate_published_at do
          require_atomic? false
          accept [:published_at]
        end

        # Internal: attribute an imported record to its original author (#950).
        #
        # `:create` carries `relate_actor(:author)`, which stamps whoever is
        # running the import — correct for authored content, wrong for migrated
        # content, where the byline belongs to whoever wrote it on the old site.
        # Its own action for the same reason the two above are: `:update` would
        # fire `NotifyWebhooks` and `FireArtifacts` for what is bookkeeping.
        #
        # The create still runs under the OPERATOR's actor, so an import can
        # never mint content a mapped author was not allowed to create; only the
        # attribution moves afterwards.
        update :reassign_author do
          require_atomic? false
          accept [:author_id]
        end

        # Internal: write resolved oEmbed metadata back onto the blocks (#489).
        #
        # Its own action rather than `:update`, for the reasons `:set_embedding`
        # is: `:update` carries `optimistic_lock`, `NotifyWebhooks` and
        # `FireArtifacts`, and is not in `ignore_actions`. Resolving one embed
        # on a published post through it would emit a spurious `updated` webhook
        # to every subscriber, re-fire every artifact, cut a history version
        # attributed to nobody, and bump `updated_at` (reordering
        # `updated_at`-sorted feeds and sitemaps) plus `lock_version` — which,
        # since the resolve is enqueued from `:autosave` too, would land while
        # an editor is typing and make their next autosave a `StaleRecord`.
        #
        # Artifacts still need re-firing so the card reaches delivery, but that
        # is the worker's decision (only when the document is published), not a
        # side effect of every metadata write.
        update :set_oembed_metadata do
          require_atomic? false
          accept [:blocks]

          # `search_text` is denormalized by a change on the editorial actions,
          # and a resolved embed's title is the only text an embed block has
          # ever contributed to it. Without this, a document whose embeds
          # resolved in the background stays unsearchable by those titles until
          # some unrelated save happens to recompute it.
          change KilnCMS.CMS.Changes.SetSearchText

          # `updated_at` still moves: Ash writes it on every update action and a
          # change cannot override that. It is bounded rather than fixed — a
          # resolve only ever runs seconds after the save that enqueued it, and
          # a resolved document never re-enqueues (`EnqueueOEmbed` requires a
          # blank title), so the bump lands on a document whose `updated_at` had
          # just moved anyway. What would have been a real problem is the
          # *version*, the *webhook* and the *lock*, and this action carries
          # none of those.
        end

        # Internal: recompute `search_text` against the fragment-expanded block
        # tree, written by `KilnCMS.Firing.Engine.fire/2` (#910).
        #
        # A `%Fragment{}` block's own `search_text/1` is always `""` — it
        # renders nothing itself — so the denormalized `search_text`
        # `Changes.SetSearchText` sets on the editorial actions never carries a
        # fragment's words: those actions see only the raw, unexpanded tree.
        # `fire/2` already builds the expanded one for the rendered surfaces;
        # this is its own action for the same reasons `:set_oembed_metadata`
        # is — no webhook, no re-fired version, no lock bump for a derived
        # column — and accepts no `:blocks`, since this never touches the
        # document's own stored content, only the search text summarizing it.
        update :reindex_search_text do
          require_atomic? false
          argument :search_text, :string, allow_nil?: false
          change set_attribute(:search_text, arg(:search_text))
        end

        # Internal: advance the materialized "what's on" sort key once an
        # occurrence has gone by (#766), written by `KilnCMS.Events.Sweep`.
        #
        # Its own action for the reasons `:set_embedding` and
        # `:set_oembed_metadata` are, and more sharply: this one fires on a
        # SCHEDULE, over rows nobody touched. Through `:update` a nightly sweep
        # of a venue's back catalogue would cut a history version per event
        # attributed to nobody, emit an `updated` webhook per event to every
        # subscriber, re-fire every artifact, and bump `lock_version` — turning
        # an open editor's next save into a `StaleRecord` because a gig finished.
        #
        # Excluded from PaperTrail (see `ignore_actions`), and nothing is busted:
        # the delivery index is not response-cached, and its `cache-control`
        # window is shorter than the sweep's period.
        update :set_next_occurrence do
          require_atomic? false
          # Nullable on purpose — an event whose series has ended advances to
          # "nothing coming up", and that is a write of `nil`, not a skip.
          argument :next_occurrence_at, :utc_datetime_usec, allow_nil?: true
          change set_attribute(:next_occurrence_at, arg(:next_occurrence_at))
        end
      end

      # `word_count`, `path`, `effective_seo_*`, `related_links`, `block_ids`
      # have no `expression/2` (computed in Elixir, not SQL) and are declared
      # `sortable? false` for it — but Ash's own sort-field resolution only
      # honors that flag across a relationship, not for a local sort, so
      # `sort=word_count` would otherwise crash instead of being rejected
      # like `filter[word_count]=...` already is. Applies to every read
      # action (`:read`, `:published`, `:trashed`, ...), not just the
      # primary one — see the preparation module.
      preparations do
        prepare KilnCMS.CMS.Preparations.RejectUnsortableCalculations
      end

      # Invalidate the public delivery cache whenever published content changes
      # (applies to every create/update/destroy action; no-ops for draft-only
      # writes — see the change module).
      changes do
        change KilnCMS.CMS.Changes.BustContentCache, on: [:create, :update, :destroy]

        # Per-field write scoping for editors (granular RBAC #332, slice 3):
        # when the editor's effective `field_grants` names this type, changing
        # an attribute outside the grant rejects the write. One generic change
        # on every update action — transitions carry no content attributes and
        # pass untouched; admins are exempt (see the change module).
        change KilnCMS.CMS.Changes.EnforceFieldGrants, on: [:update]

        # Block field policies (#51): `editable_by` on a `Kiln.Block` field was
        # enforced only by the editor filtering the fields it renders, so the
        # write API / MCP / GraphQL could set an admin-only field as an editor.
        # Checks the cast block tree in a before_action hook; admins exempt.
        change KilnCMS.CMS.Changes.EnforceBlockFieldPolicy, on: [:create, :update]

        # A fragment block's `ref` had no write-time check (#911 follow-up to
        # #479): a dangling target saved cleanly, and the target read ran
        # `authorize?: false` even though the picker offering it is
        # actor-scoped. Resolves each fragment's target under the ACTING
        # actor's own read policy; admins/system writes exempt (see the
        # change module).
        change KilnCMS.CMS.Changes.ValidateFragmentReferences, on: [:create, :update]

        # Tamper-evident history (#356): with `audit_anchor_every_write` on,
        # extend the signed anchor chain after every versioned write, closing
        # the between-publish window. Off by default and skipped for publishes
        # (RecordPublishedVersion anchors those) — see the change module.
        change KilnCMS.CMS.Changes.AnchorVersion, on: [:create, :update, :destroy]
      end

      validations do
        # A content slug is a URL component by definition (#1062). Same charset
        # as taxonomy (#1044): lowercase letters, digits, and single hyphens
        # between them. `DeriveSlug` already produces conforming values for the
        # generated path; this catches explicit slugs from the editor, JSON:API,
        # and importers that would otherwise persist `a/b` as a live path.
        validate match(:slug, ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/) do
          # Only when the slug is being written. Without this, `Match` reads the
          # attribute's *current* value on every update, so a row stored before
          # this rule existed could no longer be edited at all — renaming a
          # title, or changing blocks, would fail on a slug field nobody touched,
          # and the only way out would be to change a live public URL. Declining
          # to migrate legacy rows and then freezing them is the worst of both.
          where changing(:slug)
          message "must be lowercase letters, digits and single hyphens between them"
        end
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

        # Hard delete (`:purge`) is never available to any API key, whatever its
        # scope or the owning user's role — an automation credential has no
        # business permanently destroying content (the write API doesn't route
        # it either). Reversible removals (soft-delete/unpublish/archive) remain.
        policy action(:purge) do
          forbid_if AshAuthentication.Checks.UsingApiKey
          authorize_if always()
        end

        # Soft-delete (`:destroy`, AshArchival — reversible via restore) follows
        # the write scope like create/update (#330): a read-only key can never
        # delete; a `:read_write` key falls through to the owning user's role
        # (admin-only, per the destroy policy below), same model as `/mcp`.
        policy action(:destroy) do
          forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
          authorize_if always()
        end

        # Admins may do anything.
        bypass KilnCMS.CMS.Checks.OrgAdmin do
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
        # Drafts/in-review/archived remain editors-only. The audience grant
        # resolves PER-ORG through `Checks.InAudience` (#337 Phase 2): reading it
        # off the global `User.audiences` column made a membership bought on one
        # site widen access on every other, since memberships are org-scoped while
        # that column is not. An anonymous caller resolves to `[]` and is simply
        # not authorized by that grant, rather than erroring.
        # Granular RBAC read axis (#332): the editors-see-everything grant is
        # scoped by the editor's effective `readable_types` — empty means all
        # (the default). A restricted editor reading an out-of-scope type falls
        # through to the published/audience filters below, i.e. reads it like
        # any signed-in consumer.
        policy action_type(:read) do
          authorize_if KilnCMS.CMS.Checks.ReadableContentType
          authorize_if expr(^ref(:state) == :published and ^ref(:audience) == :public)
          authorize_if KilnCMS.CMS.Checks.InAudience
        end

        # Passphrase-locked content (#496) is invisible to every authorized
        # read. A SEPARATE policy block, because Ash ANDs policies and ORs the
        # checks within one: folding this into the block above would have made
        # the lock an alternative grant, so an `InAudience` reader would have
        # read a locked document without the passphrase. The issue asks for the
        # opposite — a lock applies "regardless of audience".
        #
        # This one block is what keeps locked content out of the sitemap, the
        # feeds, `llms.txt`, the calendar, ActivityPub, keyword/semantic search
        # and related-content. Every one of those reads actorless with
        # `authorize?: true`, so none of them needs (or gets) its own filter —
        # and a surface added later inherits the exclusion instead of having to
        # remember it.
        #
        # Delivery is the deliberate exception: `:public_by_slug` and friends run
        # `authorize?: false`, so their own filters carry the unlock grant.
        # Editors still see everything through `ReadableContentType` (and admins
        # through the bypass above); a *restricted* editor reading an
        # out-of-scope type reads it as a consumer does, which here means they
        # need the passphrase too.
        policy action_type(:read) do
          authorize_if KilnCMS.CMS.Checks.ReadableContentType
          authorize_if expr(is_nil(^ref(:access_password_hash)))
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
          authorize_if KilnCMS.CMS.Checks.OrgAdmin
        end

        # Sending reviewed content back to the author is admin-only.
        policy action(:return_to_draft) do
          authorize_if KilnCMS.CMS.Checks.OrgAdmin
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

        # The owning organization (epic #336 — Ash `:attribute` multitenancy).
        # Set automatically: Ash force-changes it from the tenant on a
        # tenant-scoped create, and this `default` stamps the default org on a
        # tenant-less create (`global?: true`), so existing single-tenant writes
        # keep working. Never accepted from API input (`writable?: false` and
        # absent from `default_accept`) — it's the sole cross-site boundary.
        attribute :org_id, :uuid do
          allow_nil? false
          default &KilnCMS.Accounts.default_org_id/0
          writable? false
          public? false
        end

        attribute :title, :string,
          allow_nil?: false,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.line()]

        attribute :slug, :string,
          allow_nil?: false,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.identifier()]

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

        attribute :seo_title, :string,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.line()]

        attribute :seo_description, :string,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.paragraph()]

        # Comma-separated keyphrases; the first is the focus keyphrase and
        # drives slug auto-derivation (Yoast-style: slug = focus keyphrase).
        attribute :seo_keywords, :string,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.line()]

        # Optional multi-segment path alias (#485): when set, the record's
        # canonical public URL (`/acupuncture/needle/size/14mm`) — the flat
        # `/<prefix>/<slug>` URL 301s to it. The slug stays the single-segment
        # internal handle. Validated by `Validations.PathAliasValid`.
        attribute :path_alias, :string,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.url()]

        # og:image URL and rel=canonical for SEO/social.
        attribute :seo_image, :string,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.url()]

        attribute :canonical_url, :string,
          public?: true,
          constraints: [max_length: KilnCMS.Limits.url()]

        attribute :locale, :string,
          default: "en",
          public?: true,
          constraints: [max_length: KilnCMS.Limits.identifier()]

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

        # Shared-passphrase lock for PUBLISHED content (#496). Independent of
        # `audience` and composed by AND: a locked record inside a gated
        # audience needs both. `nil` (the default) means unlocked, which is
        # what every existing row is.
        #
        # Never public on any API and never in a delivery projection — the only
        # reads that select it are the unlock endpoints, which need it to verify
        # a submitted passphrase. See `KilnCMS.CMS.ContentPassword` for why the
        # fingerprint exists alongside it.
        attribute :access_password_hash, :string do
          public? false
          sensitive? true
        end

        # `sha256(access_password_hash)` — what an unlock grant names. Kept as a
        # stored column rather than computed per request so the delivery read
        # can match it **in the filter**: that makes passphrase rotation
        # invalidate every outstanding grant structurally, instead of relying on
        # a controller check.
        attribute :password_fingerprint, :string do
          public? false
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

        # Denormalized "when is this on next", maintained by
        # `Changes.SetNextOccurrence` on write and `KilnCMS.Events.Sweep` on a
        # schedule; `nil` for the overwhelming majority of records, which carry
        # no schedule at all. `KilnCMS.Events.Index` is the argument for storing
        # it and for what `nil` means. Internal, like `search_text`: the sort is
        # applied server-side by the delivery routes, and a public attribute
        # would put a derived timestamp on every type's API surface — including
        # every type that will never have an event in it.
        attribute :next_occurrence_at, :utc_datetime_usec, public?: false

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

        # The owning organization (epic #336). The FK backs referential integrity
        # and AshAdmin display; the tenant axis itself is the `org_id` attribute
        # above (set from tenant/default), so this is not writable and not in
        # `default_accept`.
        belongs_to :organization, KilnCMS.Accounts.Organization do
          source_attribute :org_id
          define_attribute? false
          attribute_writable? false
          public? false
        end

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
          filterable? false
          sortable? false
        end

        # Reading time in whole minutes, derived from `word_count` at the
        # configured words-per-minute rate (#492) — so consumers stop each
        # reimplementing words ÷ WPM against a different constant.
        calculate :reading_time_minutes, :integer, KilnCMS.CMS.Calculations.ReadingTime do
          public? true
          # Neither this nor `word_count` has an `expression/2`, so a filter or
          # sort on them raises out of AshSql as a 500. Declaring them unusable
          # turns that into a proper rejection at the query layer.
          filterable? false
          sortable? false
        end

        # Full public URL path (type prefix + slug, e.g. `/blog/my-post`) so
        # headless consumers can link without hard-coding the URL scheme.
        calculate :path, :string, KilnCMS.CMS.Calculations.PublicPath do
          public? true
          # No `expression/2` — the path is assembled from the type registry,
          # not a column — so a filter or sort raised out of AshSql as an
          # unhandled 500 (#1139). Declaring it unusable turns that into a
          # proper `InvalidFilterReference` rejection at the query layer,
          # exactly as `word_count` and friends already do.
          filterable? false
          sortable? false
        end

        # The SEO fields as anything *rendering* them should read them: the
        # author's own value, else the type's #805 pattern expanded (#1102).
        # The stored `seo_title`/`seo_description` keep saying exactly what a
        # human typed — which is what the editor's SEO panel, the analyzer and
        # the export need them to say — so this is a second field rather than a
        # change to the first.
        calculate :effective_seo_title,
                  :string,
                  {KilnCMS.CMS.Calculations.EffectiveSeo, field: :seo_title} do
          public? true
          # No `expression/2` — the pattern lives in the type registry, not in a
          # column — so a filter or sort on this would raise out of AshSql as a
          # 500. Declaring them unusable rejects at the query layer instead,
          # exactly as `word_count` and `related_links` do.
          filterable? false
          sortable? false
        end

        calculate :effective_seo_description,
                  :string,
                  {KilnCMS.CMS.Calculations.EffectiveSeo, field: :seo_description} do
          public? true
          filterable? false
          sortable? false
        end

        # The curated related links, projected to `[%{id, title, slug}]` (#996).
        # A calculation rather than `load [related_*s: [...]]` because `load`
        # cannot project — see `KilnCMS.CMS.Calculations.RelatedLinks`.
        calculate :related_links,
                  {:array, :map},
                  {KilnCMS.CMS.Calculations.RelatedLinks, relationship: unquote(related_name)} do
          public? true
          # No expression, so a filter or sort would raise out of AshSql as a
          # 500; declaring them unusable rejects at the query layer instead —
          # same reason `word_count` does.
          filterable? false
          sortable? false
        end

        # The block tree projected to `_id`/`_type` only, nested children in
        # the positions they render (#954). This is the READ surface for block
        # identity: the write path accepts `_id` back, and `EnforceBlockFieldPolicy`
        # requires a nested admin-set value to return under the child id that
        # held it — a demand that is only fair because this makes the ids
        # readable on drafts (the fired artifact covers published content).
        # Carries no field values, so the non-`public?` `blocks` boundary and
        # `hide_inputs: [:blocks]` are untouched; drafts stay editor-scoped by
        # the row read policy.
        calculate :block_ids, {:array, :map}, KilnCMS.CMS.Calculations.BlockIds do
          public? true
          # No `expression/2`, so a filter or sort would raise out of AshSql as
          # a 500; declaring them unusable rejects at the query layer instead —
          # same reason `word_count` does.
          filterable? false
          sortable? false
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
