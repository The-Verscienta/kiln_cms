defmodule KilnCMS.CMS.SavedView do
  @moduledoc """
  A named, saved filter on the console's content list (#1593).

  The content list keeps its whole filter — status, type, author, category,
  tag, locale, date range, health, sort — in the URL, so a link already
  reproduces a view. A saved view is that URL state given a name and a row:
  `params` holds the same string-keyed query parameters the list reads, and
  nothing else.

  ## Who sees which view

  * A view is **private** by default: its owner sees it, and nobody else
    except an admin of the site.
  * An admin can mark a view `shared`. A shared view is listed for every
    editor of the site, which is how an admin pins a view for the team.
    Only an admin may share, edit or delete a shared view, so an editor cannot
    rename the team's view out from under everyone.
  * Every read and write is scoped to the site (`org_id`): a view saved on one
    site is never listed on another.

  ## `params` is checked, not trusted

  The map is reduced to the keys in `param_keys/0`, each a short string, on
  every write. The list re-validates every value when it applies a view (an
  unknown type, a deleted category or a malformed date falls back to "any"),
  so a stale view narrows less rather than failing.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Limits

  # The query parameters the content list understands — the only keys a view
  # can store. `KilnCMSWeb.EditorLive.Filters` reads the same list.
  @param_keys ~w(status type q author category tag locale from to health scheduled sort)

  # Each value is a short token, an id or a search string; none needs more.
  @max_param_length 200

  @doc "The query-parameter keys a saved view may store."
  @spec param_keys() :: [String.t()]
  def param_keys, do: @param_keys

  @doc """
  `params` reduced to the keys in `param_keys/0` whose values are non-empty
  strings of at most #{@max_param_length} characters.
  """
  @spec clean_params(term()) :: %{optional(String.t()) => String.t()}
  def clean_params(params) when is_map(params) do
    for {key, value} <- params,
        key = to_string(key),
        key in @param_keys,
        is_binary(value),
        value = String.trim(value),
        value != "",
        String.length(value) <= @max_param_length,
        into: %{},
        do: {key, value}
  end

  def clean_params(_params), do: %{}

  postgres do
    table "saved_views"
    repo KilnCMS.Repo

    references do
      # A view belongs to one account and means nothing without it.
      reference :owner, on_delete: :delete
    end

    custom_indexes do
      # The list's only read: one site's views owned by the actor, plus that
      # site's shared ones. Both halves lead on `org_id`; the shared half is a
      # handful of rows per site, filtered in the heap.
      index [:org_id, :owner_id], name: "saved_views_owner_lookup_index"
    end
  end

  actions do
    defaults [:read, :destroy]

    read :visible do
      description "The actor's own views and the site's shared views, by name."

      filter expr(owner_id == ^actor(:id) or shared == true)
      prepare build(sort: [shared: :desc, name: :asc])
    end

    create :create do
      description "Save the current content-list filter under a name."
      primary? true
      accept [:name, :params, :shared]

      change relate_actor(:owner)
      change {KilnCMS.CMS.SavedView.CleanParams, []}
    end

    update :update do
      description "Rename a view, replace its filter, or share it with the site."
      primary? true
      accept [:name, :params, :shared]
      require_atomic? false

      change {KilnCMS.CMS.SavedView.CleanParams, []}
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # The content list is an editor's screen, so a view is too: a viewer has
    # no list to save one from.
    policy action_type(:read) do
      forbid_unless KilnCMS.CMS.Checks.OrgEditor
      authorize_if expr(owner_id == ^actor(:id))
      authorize_if expr(shared == true)
    end

    # Sharing is an admin's (the bypass above). An editor saves private views.
    policy action_type(:create) do
      forbid_unless KilnCMS.CMS.Checks.OrgEditor
      forbid_if changing_attributes(shared: [to: true])
      authorize_if always()
    end

    # An editor manages their own private views only — never a shared one,
    # even one they own, since the whole team reads it.
    policy action_type([:update, :destroy]) do
      forbid_unless KilnCMS.CMS.Checks.OrgEditor
      forbid_if changing_attributes(shared: [to: true])
      authorize_if expr(owner_id == ^actor(:id) and shared == false)
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning site (epic #336). Set from the tenant, never from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: Limits.identifier(), trim?: true
    end

    # String-keyed query parameters, as the content list's URL carries them.
    attribute :params, :map do
      allow_nil? false
      default %{}
      public? true
    end

    # Listed for every editor of the site, not just the owner. Admin-only.
    attribute :shared, :boolean do
      allow_nil? false
      default false
      public? true
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

    belongs_to :owner, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? false
      public? true
    end
  end
end
