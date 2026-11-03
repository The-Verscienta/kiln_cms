defmodule KilnCMS.CMS.SearchSynonym do
  @moduledoc """
  A site's search synonyms and aliases (proposal A7): words its readers search
  by that its content does not use, so "reishi" finds the page titled
  "Ling Zhi".

  Two kinds of rule:

    * `:group` — every term names the same thing, in both directions:
      `reishi ⇄ ling zhi ⇄ ganoderma`. A query naming any of them is also
      searched under each of the others.
    * `:one_way` — the `terms` expand to `expands_to` and not back:
      `tcm → traditional chinese medicine` makes "tcm" find the long form, but
      a search for the long form is not widened to every page that says "tcm".

  A term may be several words ("ling zhi"); it matches a query at word
  boundaries, case-insensitively, wherever it appears in it. Terms are stored
  trimmed, lowercased and with their inner whitespace collapsed, so the
  console shows what the matcher compares.

  Applied at query time by `KilnCMS.Search.Synonyms`, inside
  `KilnCMS.Search.hybrid/3` — so every surface built on it (`/api/search`,
  `/api/ask`, the `/mcp` `search_content` tool, the editor palette, the public
  `/search` page) answers the same way, with no consumer code. An alternate
  wording is weighted below the user's own (`Search.hybrid/3`'s `:synonym`
  leg), and the alternates a search ran are reported back
  (`also_searched` on `/api/search`).

  Search config, not content: editors and admins read and write rules at
  `/editor/search-synonyms`, and only an admin deletes one (an editor turns a
  rule off with `enabled`). The search legs read the rules as the system
  actor of the `:search` subsystem, since the searcher is usually anonymous.
  Every write busts the site's cached rule set and purges its CDN key
  (`Changes.SynonymsChanged`): a rule changes what an anonymous, publicly
  cached `/api/search` URL answers.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "search_synonyms"
    repo KilnCMS.Repo

    # Every search reads one site's rules.
    custom_indexes do
      index [:org_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:kind, :terms, :expands_to, :enabled]
    end

    # Not atomic: the terms are normalized and the rule checked in Elixir.
    update :update do
      primary? true
      accept [:kind, :terms, :expands_to, :enabled]
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # A read-only API key never writes search config, and no key deletes it —
    # before the admin bypass, so an admin's key cannot skip it (the taxonomy
    # rule).
    policy action_type([:create, :update]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    policy action_type(:destroy) do
      forbid_if AshAuthentication.Checks.UsingApiKey
      authorize_if always()
    end

    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # The search legs read the rules for whoever is searching — usually an
    # anonymous visitor — as the system actor (`KilnCMS.Search.Synonyms`).
    # Nobody else outside the site's editors needs them.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :search}
    end

    policy action_type([:create, :update]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Hard delete is admin-only (the bypass above); an editor turns a rule off.
    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  changes do
    change KilnCMS.CMS.Changes.NormalizeSynonymTerms, on: [:create, :update]
    change KilnCMS.CMS.Changes.SynonymsChanged, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.SynonymRule, on: [:create, :update]
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336): set from the tenant, never accepted
    # from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :kind, :atom do
      allow_nil? false
      default :group
      public? true
      constraints one_of: [:group, :one_way]
    end

    # `:group` — the equivalent terms (two or more). `:one_way` — the terms a
    # query is matched on (one or more).
    attribute :terms, {:array, :string} do
      allow_nil? false
      default []
      public? true
      # `nil_items?`: a blank entry ("reishi, , ling zhi") casts to nil, and
      # `Changes.NormalizeSynonymTerms` drops it rather than the cast
      # refusing the whole list.
      constraints min_length: 1, max_length: 20, nil_items?: true, items: [max_length: 200]
    end

    # `:one_way` only — what the terms expand to. Always empty on a group.
    attribute :expands_to, {:array, :string} do
      allow_nil? false
      default []
      public? true
      constraints max_length: 20, nil_items?: true, items: [max_length: 200]
    end

    # Off keeps the rule without applying it.
    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
    end
  end
end
