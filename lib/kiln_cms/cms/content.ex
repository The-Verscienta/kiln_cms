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
    * `:table` — the Postgres table; defaults to `"\#{type}s"`.
    * `:excerpt?` — include an `excerpt` attribute (listings/feeds). Default `false`.
    * `:published?` — add a `:published` read (published-only, newest first).
      Default `false`.

  Per-type extras (custom attributes, extra actions) are declared in the using
  module as usual — Spark merges them with what this macro injects.
  """
  # Days trashed content is retained before the nightly auto-purge.
  @trash_retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)
    table = Keyword.get(opts, :table, "#{type}s")
    excerpt? = Keyword.get(opts, :excerpt?, false)
    published? = Keyword.get(opts, :published?, false)

    # Derive the per-type names from `type` by the project's naming convention.
    resource = __CALLER__.module
    related_name = :"related_#{type}s"
    related_arg = :"related_#{type}_ids"

    # AshOban worker/scheduler module names (kept identical to hand-written ones).
    pub_worker = Module.concat([resource, Workers, PublishScheduled])
    pub_scheduler = Module.concat([resource, Schedulers, PublishScheduled])
    purge_worker = Module.concat([resource, Workers, PurgeTrashed])
    purge_scheduler = Module.concat([resource, Schedulers, PurgeTrashed])

    accept =
      [:title, :slug] ++
        if(excerpt?, do: [:excerpt], else: []) ++
        [
          :blocks,
          :seo_title,
          :seo_description,
          :seo_image,
          :canonical_url,
          :locale,
          :scheduled_at,
          :category_id,
          :featured_image_id
        ]

    excerpt_attribute =
      if excerpt? do
        quote do
          attribute :excerpt, :string, public?: true
        end
      end

    published_read =
      if published? do
        quote do
          # Public delivery: published content, newest first.
          read :published do
            filter expr(^ref(:state) == :published)
            prepare build(sort: [published_at: :desc])
          end
        end
      end

    quote do
      use Ash.Resource,
        domain: KilnCMS.CMS,
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [
          AshPaperTrail.Resource,
          AshStateMachine,
          AshOban,
          AshArchival.Resource,
          AshJsonApi.Resource,
          AshGraphql.Resource,
          AshAdmin.Resource
        ]

      graphql do
        type unquote(type)
      end

      json_api do
        type unquote(Atom.to_string(type))
      end

      paper_trail do
        change_tracking_mode(:changes_only)
        store_action_name?(true)
        ignore_attributes([:inserted_at, :updated_at])
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
          transition :publish, from: [:draft, :in_review], to: :published
          transition :publish_scheduled, from: [:draft, :in_review], to: :published
          transition :unpublish, from: :published, to: :draft
          transition :archive, from: [:draft, :in_review, :published], to: :archived
        end
      end

      # Background publishing of scheduled content + nightly purge of old trash.
      oban do
        triggers do
          trigger :publish_scheduled do
            action :publish_scheduled
            queue :default
            scheduler_cron "* * * * *"

            where expr(
                    ^ref(:state) in [:draft, :in_review] and not is_nil(^ref(:scheduled_at)) and
                      ^ref(:scheduled_at) <= now()
                  )

            worker_read_action :read
            worker_module_name unquote(pub_worker)
            scheduler_module_name unquote(pub_scheduler)
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

        # GIN functional index backing the `:search` action — its expression
        # matches the `to_tsvector(...)` in that action's filter exactly so the
        # planner can use it instead of scanning every row.
        custom_indexes do
          index ["to_tsvector('english', coalesce(search_text, ''))"],
            name: unquote("#{table}_search_text_gin_index"),
            using: "gin"
        end
      end

      actions do
        defaults [:read, :destroy]

        default_accept unquote(accept)

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

          change KilnCMS.CMS.Changes.SanitizeBlocks
          change KilnCMS.CMS.Changes.SetSearchText
        end

        update :update do
          primary? true
          require_atomic? false
          argument :tag_ids, {:array, :uuid}
          argument unquote(related_arg), {:array, :uuid}
          change manage_relationship(:tag_ids, :tags, type: :append_and_remove)

          change manage_relationship(unquote(related_arg), unquote(related_name),
                   type: :append_and_remove
                 )

          change KilnCMS.CMS.Changes.SanitizeBlocks
          change KilnCMS.CMS.Changes.SetSearchText
        end

        # Full-text search over the denormalized `search_text`. Goes through the
        # read policy, so anonymous callers only match published content.
        read :search do
          argument :query, :string, allow_nil?: false

          filter expr(
                   fragment(
                     "to_tsvector('english', coalesce(?, '')) @@ plainto_tsquery('english', ?)",
                     ^ref(:search_text),
                     ^arg(:query)
                   )
                 )
        end

        update :submit_for_review do
          require_atomic? false
          change transition_state(:in_review)
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :submitted_for_review}
        end

        update :publish do
          require_atomic? false
          change transition_state(:published)
          change set_attribute(:published_at, &DateTime.utc_now/0)
          change KilnCMS.CMS.Changes.NotifyWebhooks
          change {KilnCMS.CMS.Changes.NotifyWorkflowEmail, event: :published}
        end

        update :publish_scheduled do
          # Run by the AshOban scheduler once `scheduled_at` has passed.
          require_atomic? false
          change transition_state(:published)
          change set_attribute(:published_at, &DateTime.utc_now/0)
          change set_attribute(:scheduled_at, nil)
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
          change KilnCMS.CMS.Changes.SanitizeBlocks
        end

        update :unpublish do
          require_atomic? false
          change transition_state(:draft)
          change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "unpublished"}
        end

        update :archive do
          require_atomic? false
          change transition_state(:archived)
        end

        # Public delivery: fetch a single published record by slug. The `state ==
        # :published` filter is the security boundary, so it's safe without an
        # actor (anonymous site visitors).
        read :public_by_slug do
          get? true
          argument :slug, :string, allow_nil?: false
          filter expr(^ref(:state) == :published and ^ref(:slug) == ^arg(:slug))
        end

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
        end
      end

      policies do
        # The AshOban scheduler publishes scheduled content as a trusted job.
        bypass AshOban.Checks.AshObanInteraction do
          authorize_if always()
        end

        # Admins may do anything.
        bypass actor_attribute_equals(:role, :admin) do
          authorize_if always()
        end

        # Published content is world-readable (headless delivery / public site);
        # unpublished content (draft/in_review/archived) is editors-only.
        policy action_type(:read) do
          authorize_if expr(^ref(:state) == :published)
          authorize_if actor_attribute_equals(:role, :editor)
        end

        # Authoring and workflow transitions are reserved for editors (and admins
        # via the bypass above). Every state-machine action is an update action.
        policy action_type([:create, :update]) do
          authorize_if actor_attribute_equals(:role, :editor)
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

        attribute :blocks, {:array, KilnCMS.CMS.Block} do
          default []
          public? true
        end

        attribute :seo_title, :string, public?: true
        attribute :seo_description, :string, public?: true
        # og:image URL and rel=canonical for SEO/social.
        attribute :seo_image, :string, public?: true
        attribute :canonical_url, :string, public?: true
        attribute :locale, :string, default: "en", public?: true
        attribute :published_at, :utc_datetime_usec, public?: true

        # When set in the future, the AshOban scheduler publishes this record once
        # the time passes (cleared on publish).
        attribute :scheduled_at, :utc_datetime_usec, public?: true

        # Denormalized plain-text maintained by `Changes.SetSearchText` and
        # queried by the `search` action. Internal.
        attribute :search_text, :string

        timestamps()
      end

      relationships do
        # The user who authored this record. Nullable so existing/system content
        # without an actor is valid. Not exposed via the public APIs.
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
      end

      calculations do
        # Convenience flag for the published state (no `?` suffix — GraphQL names
        # can't contain it).
        calculate :published, :boolean, expr(^ref(:state) == :published) do
          public? true
        end

        # Total word count across the embedded block tree.
        calculate :word_count, :integer, KilnCMS.CMS.Calculations.WordCount do
          public? true
        end
      end

      identities do
        identity :unique_slug, [:slug, :locale]
      end

      # Marks this resource as a KilnCMS content type and records its singular
      # type atom. `KilnCMS.CMS.ContentTypes` uses this to discover content types
      # automatically, so generated types appear in the admin with no extra
      # wiring.
      def __kiln_content_type__, do: unquote(type)
    end
  end
end
