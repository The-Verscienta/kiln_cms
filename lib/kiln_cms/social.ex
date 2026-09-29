defmodule KilnCMS.Social do
  @moduledoc """
  Social auto-posting on publish (#497) — "content published → announce it".

  A `:social_post` reaction on an editorial automation rule
  (`KilnCMS.Automation`), not a new subsystem: the trigger, the queue, the
  scoping and the admin surface all already exist. What is new is a credential
  store (`KilnCMS.Social.Account`), a ledger (`KilnCMS.Social.Post`), and two
  provider implementations.

  ## Bluesky and Mastodon, and nothing else in core

  Both have open, stable, free APIs that need no app-review process: an AT
  Protocol app password, a Mastodon access token. X, LinkedIn and Facebook are
  deliberately plugin territory through `KilnCMS.Social.Provider` — their APIs
  are volatile, paid, and gated behind review, and a core module for one of them
  is a maintenance burden every deployment inherits whether or not it uses it.

  ## Not the same thing as federation

  `KilnCMS.Federation` (#491) makes Kiln *itself* a fediverse actor that people
  follow. This posts to accounts the operator already has, on networks they
  already use. They complement rather than compete, and an operator may well
  want both — which is why a locked or gated document is refused by both, in
  each one's own guard, rather than by a shared one that either could forget to
  call.

  ## At most once, and the asymmetry behind it

  A duplicate announcement is worse than a missing one. A missing post is
  invisible; a duplicate is on the operator's public timeline, in front of their
  audience, and cannot be quietly undone. So:

    * the ledger row is a **claim**, written before the request, unique on
      {rule, account, document, publish};
    * an ambiguous outcome is recorded as `:unknown` and **never auto-retried**;
    * the announce worker runs with `max_attempts: 1`.

  The cost is that a genuinely lost post stays lost until someone looks. That is
  the right side to fail on here, and `docs/social-posting.md` says so plainly
  rather than implying a delivery guarantee the design does not make.
  """
  use Ash.Domain

  require Logger

  resources do
    resource KilnCMS.Social.Account do
      define :list_accounts, action: :read
      define :get_account, action: :read, get_by: [:id]
      define :accounts_for_provider, action: :enabled_for_provider, args: [:provider]
      define :create_account, action: :create
      define :update_account, action: :update
      define :record_account_post, action: :record_post
      define :destroy_account, action: :destroy
    end

    resource KilnCMS.Social.Post do
      define :list_posts, action: :read
      define :recent_posts, action: :recent
      define :claim_post, action: :claim
      define :succeed_post, action: :succeed
      define :fail_post, action: :fail
      define :unresolved_post, action: :unresolved
      define :skip_post, action: :skip
    end
  end

  @doc """
  Whether any provider is configured for this site.

  Cheap enough for the reaction to ask before doing anything else: an install
  that has never opened the settings page pays one cached lookup per publish.
  """
  @spec configured?(Ash.UUID.t()) :: boolean()
  def configured?(org_id) do
    # Read as `system/0` (#1659). A refused read would filter to `[]`, which
    # reads as "not configured": the same answer this gives when it cannot
    # tell, and the safe one here (a missing announcement is the side the
    # module fails on; see "At most once" above). `authorize_with: :error`
    # does not change the answer. It makes a lost grant a raise, which is
    # never cached, and which the rescue below LOGS instead of passing
    # silently.
    KilnCMS.Cache.fetch(KilnCMS.Cache.social_accounts_key(org_id), :timer.minutes(5), fn ->
      list_accounts!(actor: system(), authorize_with: :error, tenant: org_id)
      |> Enum.any?(& &1.enabled)
    end)
  rescue
    error ->
      Logger.error(
        "Social accounts for org #{org_id} could not be read, not announcing: " <>
          Exception.message(error)
      )

      false
  end

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor social auto-posting runs as (#1659): `configured?/1`'s account
  read and `KilnCMS.Social.Announcer`'s ledger claim and settlement.

  A `KilnCMS.SystemActor`, admitted by action name on `Social.Account` (the
  reads and `record_post`) and `Social.Post` (`claim` and the four settling
  updates); see `docs/policy-matrix.md`, "The system actor". It may not mint,
  edit or delete an account's credentials, nor read or delete a ledger row.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:social)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process, so a test can take the grant away and prove that a refused claim
  # posts nothing. Process-local, and nothing on a request path calls it; code
  # that could call it could equally pass any actor it liked. (A read inside
  # `KilnCMS.Cache.fetch/3` runs in Cachex's courier process and does not see
  # the override; disable the cache to exercise one.)
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  @doc "Drop the cached answer for `configured?/1` — called on any account write."
  @spec bust(Ash.UUID.t()) :: :ok
  defdelegate bust(org_id), to: KilnCMS.Cache, as: :bust_social_accounts

  @doc """
  Extra `Req` options for the provider HTTP calls.

  The seam the suite stubs through (`req_options: [plug: {Req.Test, …}]`), the
  same shape `KilnCMS.Unsplash` and `KilnCMS.OEmbed` use. Empty in production —
  and it must stay a *merge* at the call site, since replacing the option list
  would drop SafeFetch's own address pinning.
  """
  @spec req_options() :: keyword()
  def req_options do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end

  @doc """
  The canonical public URL of a published document — what an announcement links
  to.

  Built from the record's own `canonical_url` when the editor set one, else the
  site's delivery URL for its type and slug. A `path_alias` (#485) wins over the
  flat slug path, because the flat path 301s to it and a redirect in a social
  post is a link preview that resolves to the wrong URL.
  """
  @spec canonical_url(struct()) :: String.t()
  def canonical_url(record) do
    # `authorize?: false` kept (#1659): one organization by primary key, for
    # its public base URL. Admitting the system actor on `Organization`'s read
    # policy would be a standing read of every site on the deployment, far
    # wider than this lookup of the record's own org.
    org = KilnCMS.Accounts.get_organization!(record.org_id, authorize?: false)
    base = KilnCMSWeb.Tenant.base_url(org)

    cond do
      is_binary(record.canonical_url) and record.canonical_url != "" ->
        record.canonical_url

      is_binary(Map.get(record, :path_alias)) and Map.get(record, :path_alias) != "" ->
        base <> record.path_alias

      true ->
        base <> prefix(record) <> "/" <> record.slug
    end
  end

  # `public_prefix/1` already answers "" or "/<segment>", so this only has to
  # survive a type that has since been archived out of the registry.
  defp prefix(record) do
    type = KilnCMS.Firing.Engine.public_type(record)

    case KilnCMS.CMS.ContentTypes.get(to_string(type), record.org_id) do
      nil -> ""
      descriptor -> KilnCMS.CMS.ContentTypes.public_prefix(descriptor)
    end
  end
end
