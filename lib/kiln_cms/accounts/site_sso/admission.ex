defmodule KilnCMS.Accounts.SiteSso.Admission do
  @moduledoc """
  Who a site's own identity provider may sign in (#1561).

  `KilnCMS.Accounts.SiteSso` has already verified the ID token — signature,
  issuer, audience, expiry, nonce. That proves *the site's provider* asserted
  these claims. It proves nothing about whether the site may speak for the
  account they name, because accounts belong to the whole deployment and the
  provider is one a site admin chose. So every rule below must pass, in order,
  on every sign-in:

    1. **A verified email.** The claims carry `email`, and `email_verified` is
       `true` (or `"true"`). No opt-out, unlike the operator's
       `assume_email_verified`: a site cannot vouch for an address its own
       provider will not vouch for.
    2. **A domain the site verified.** The address's domain is one of the
       site's `KilnCMS.CMS.SiteSsoDomain` rows with `verified_at` set, **and**
       its TXT record is still published right now
       (`KilnCMS.Accounts.SiteSso.DomainCheck.published?/2`). Exact match: a
       verified `example.com` does not cover `mail.example.com`.
    3. **An account with no access anywhere else.** See below.
    4. **A confirmed account.** An existing account whose owner never confirmed
       its address may have been registered by someone else in advance (a
       pre-hijack); signing the provider's user into it would hand them that
       stranger's password too. Refused, as the operator's provider does.
    5. **No new account under invite-only.** An unknown address is provisioned
       (`:viewer`, with a `:viewer` membership on this site only) only while
       open registration is on (`:registration_enabled`).

  ## A new account may wait for approval

  When the site has `approval_for_site_sso` on (`KilnCMS.CMS.SiteRegistration`,
  #2514), a provisioned account's membership is a **pending** registration
  (`OrgMembership.:queue_registration`, `method: :site_sso`) instead of a
  `:viewer` one. The account signs in, holds nothing on any site until a site
  admin approves it under `/editor/registrations`, and the site's admins are
  told it is waiting once the account commits. The switch is independent of
  `approval_required` (password sign-ups), and it applies to new accounts
  only: an existing account is admitted by the rules above as it always was.

  The setting is read before the transaction, and only when an account would
  be provisioned. An unreadable setting refuses the sign-in
  (`:registration_settings_unavailable`) and creates nothing: letting the
  account in as a `:viewer` is the direction a site that turned approval on
  meant to prevent.

  Then, and only then, a session token is minted
  (`Accounts.complete_site_sso_sign_in/2`), and the web layer completes the
  sign-in through `KilnCMSWeb.AuthController.success/4` — so an account with a
  second factor still has to enter it.

  ## Rule 3: the cross-site line

  A site-provider sign-in yields an ordinary, deployment-wide session. Kiln has
  no session scoped to one site, so the guarantee is made at admission instead:
  **a site's provider never signs in an account that has any access on any
  other site.** Concretely it refuses an account that

    * is a platform admin — by its standing role or a live temporary grant
      (`KilnCMS.Accounts.RoleGrant.effective_role/1`);
    * holds an `OrgMembership` on any other organization, at any tier (a
      `:viewer` membership can still carry paid audiences);
    * holds no memberships at all and an `:editor` or `:admin` global role,
      when this site is not the default org — that role is a tier on the
      default org (`Scoping.effective_tier/2`'s legacy branch).

  Refused accounts can still sign in every other way (password, magic link,
  passkey, the operator's provider). The refusal is checked on every sign-in, so
  an account that gains access elsewhere later stops being admissible here from
  its next sign-in.

  What rule 3 does not cover: a session a site's provider minted *before* the
  account gained access elsewhere keeps working until it ends, like any other
  session. That is no wider than what rule 2 already concedes: whoever controls
  a domain's DNS controls its mail, and could take the same account over with a
  password reset. `docs/threat-model.md` records it.
  """

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RegistrationPolicy
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.SiteSso.DomainCheck
  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.Registrations
  alias KilnCMS.Security.Recorder
  alias KilnCMS.SystemActor

  @type refusal ::
          :no_email
          | :email_unverified
          | :domain_not_verified
          | :domain_check_failed
          | :access_elsewhere
          | :unconfirmed_account
          | :registration_disabled
          | :registration_settings_unavailable
          | :sign_in_failed

  @doc """
  Admit `claims` (a verified ID token's) to `org_id`: `{:ok, user}` with a
  session token in `user.__metadata__.token`, or `{:error, refusal}`.

  `context` is the request's Ash context (`KilnCMS.Security.AuthEvents.context/2`),
  so the audit event of a membership written here carries the client address.
  """
  @spec admit(Ash.UUID.t(), map(), map()) :: {:ok, Accounts.User.t()} | {:error, refusal()}
  def admit(org_id, claims, context \\ %{})
      when is_binary(org_id) and is_map(claims) and is_map(context) do
    write_context = Map.take(context, [Recorder.context_key(), Recorder.tenant_key()])

    with {:ok, email} <- email(claims),
         :ok <- email_verified(claims),
         :ok <- domain_verified(org_id, DomainCheck.email_domain(email)),
         {:ok, user} <- account(org_id, email, claims, write_context) do
      mint(user)
    end
  end

  @doc """
  The site's verified domains (`verified_at` set) — `:error` when they cannot
  be read, which callers treat as "none may be vouched for".
  """
  @spec verified_domains(Ash.UUID.t()) :: {:ok, [CMS.SiteSsoDomain.t()]} | :error
  def verified_domains(org_id) when is_binary(org_id) do
    # authorize?: false — a pre-auth read on the sign-in path, with no actor
    # yet. Safe: the tenant is the request's own org, and nothing read is shown.
    case CMS.list_site_sso_domains(tenant: org_id, authorize?: false) do
      {:ok, rows} -> {:ok, Enum.reject(rows, &is_nil(&1.verified_at))}
      {:error, _error} -> :error
    end
  rescue
    _exception -> :error
  end

  @doc """
  Rule 3 alone: `:ok` when `user` has no access on any org but `org_id`. Public
  so the rule can be tested exhaustively on its own.
  """
  @spec isolated(Accounts.User.t(), Ash.UUID.t()) :: :ok | {:error, :access_elsewhere}
  def isolated(user, org_id) do
    # authorize?: false — every membership the account holds, on every org, is
    # exactly the question — a caller-scoped read would hide the ones that
    # refuse. Pre-auth, and only used to decide; nothing is returned.
    memberships = Accounts.list_memberships_for_user!(user.id, authorize?: false)

    cond do
      platform_admin?(user) ->
        {:error, :access_elsewhere}

      Enum.any?(memberships, &(&1.organization_id != org_id)) ->
        {:error, :access_elsewhere}

      memberships == [] and legacy_access_elsewhere?(user, org_id) ->
        {:error, :access_elsewhere}

      true ->
        :ok
    end
  end

  @doc "A sentence fragment for a refusal, for logs."
  @spec describe_refusal(refusal()) :: String.t()
  def describe_refusal(:no_email), do: "the ID token carries no email"
  def describe_refusal(:email_unverified), do: "the provider did not verify the email"

  def describe_refusal(:domain_not_verified),
    do: "the email's domain is not one this site has verified"

  def describe_refusal(:domain_check_failed),
    do: "the site's verified domains could not be read"

  def describe_refusal(:access_elsewhere),
    do: "the account has access on another site or on the whole deployment"

  def describe_refusal(:unconfirmed_account), do: "the account's email was never confirmed"
  def describe_refusal(:registration_disabled), do: "open registration is off"

  def describe_refusal(:registration_settings_unavailable),
    do: "the site's registration settings could not be read"

  def describe_refusal(:sign_in_failed), do: "the session could not be created"
  def describe_refusal(other), do: inspect(other)

  # -- the rules -------------------------------------------------------------

  defp email(%{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :no_email}
      trimmed -> {:ok, trimmed}
    end
  end

  defp email(_claims), do: {:error, :no_email}

  defp email_verified(%{"email_verified" => value}) when value in [true, "true"], do: :ok
  defp email_verified(_claims), do: {:error, :email_unverified}

  defp domain_verified(_org_id, nil), do: {:error, :domain_not_verified}

  defp domain_verified(org_id, domain) do
    case verified_domains(org_id) do
      {:ok, rows} -> rows |> Enum.find(&(&1.domain == domain)) |> still_published()
      :error -> {:error, :domain_check_failed}
    end
  end

  # The stamp says an admin proved control once; the record has to be there
  # now, too.
  defp still_published(nil), do: {:error, :domain_not_verified}

  defp still_published(row) do
    if DomainCheck.published?(row.domain, row.verification_token),
      do: :ok,
      else: {:error, :domain_not_verified}
  end

  defp account(org_id, email, claims, write_context) do
    # authorize?: false — a pre-auth lookup of the account the verified ID
    # token names (rules 1 and 2 have passed); there is no actor to ask as.
    case Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, %Accounts.User{} = user} ->
        with :ok <- isolated(user, org_id),
             :ok <- confirmed(user) do
          {:ok, user}
        end

      _no_account ->
        provision(org_id, email, claims, write_context)
    end
  end

  defp confirmed(%{confirmed_at: %DateTime{}}), do: :ok
  defp confirmed(_user), do: {:error, :unconfirmed_account}

  defp provision(org_id, email, claims, write_context) do
    if Application.get_env(:kiln_cms, :registration_enabled, true),
      do: provision_member(org_id, email, claims, write_context),
      else: {:error, :registration_disabled}
  end

  # One transaction: an account left without its membership would be a
  # membership-less `:viewer`, whose legacy tier lands on the default org rather
  # than on this site. The approval setting is read before it opens, so no
  # connection is held for the read.
  defp provision_member(org_id, email, claims, write_context) do
    with {:ok, queue?} <- queue_new_accounts?(org_id),
         {:ok, user} <- provision_in_transaction(org_id, email, claims, queue?, write_context) do
      announce(org_id, queue?)
      {:ok, user}
    end
  end

  # After the commit: the admins are told about a row that exists.
  defp announce(org_id, true), do: AfterCommit.run(fn -> Registrations.announce_org(org_id) end)
  defp announce(_org_id, false), do: :ok

  defp provision_in_transaction(org_id, email, claims, queue?, write_context) do
    case KilnCMS.Repo.transaction(fn ->
           create_member(org_id, email, claims, queue?, write_context)
         end) do
      {:ok, user} ->
        {:ok, user}

      {:error, error} ->
        Logger.warning("Site single sign-on could not provision an account: #{inspect(error)}")
        {:error, :sign_in_failed}
    end
  end

  defp queue_new_accounts?(org_id) do
    case RegistrationPolicy.settings(org_id) do
      {:ok, settings} -> {:ok, settings.approval_for_site_sso}
      {:error, :unavailable} -> {:error, :registration_settings_unavailable}
    end
  end

  defp create_member(org_id, email, claims, queue?, write_context) do
    name = if is_binary(claims["name"]), do: claims["name"]

    # authorize?: false — the system-only provisioning action, reachable no
    # other way (see `User`'s policies), for an address that passed rules 1-2
    # and has no account yet.
    with {:ok, user} <-
           Accounts.register_with_site_sso(%{email: email, name: name}, authorize?: false),
         {:ok, _membership} <- membership(org_id, user, queue?, write_context) do
      user
    else
      {:error, error} -> KilnCMS.Repo.rollback(error)
    end
  end

  # The site requires approval for its provider's new accounts: a pending
  # registration, written by the one actor that action admits.
  defp membership(org_id, user, true, write_context) do
    Accounts.queue_registration(
      %{organization_id: org_id, user_id: user.id, method: :site_sso, new_account?: true},
      actor: SystemActor.new(:registrations),
      context: write_context
    )
  end

  defp membership(org_id, user, false, write_context) do
    # authorize?: false — membership creation is an admin action; this is
    # the system granting the new account `:viewer` on the one site whose
    # provider vouched for it, and nothing more.
    Accounts.create_org_membership(
      %{user_id: user.id, organization_id: org_id, role: :viewer},
      authorize?: false,
      context: write_context
    )
  end

  defp mint(user) do
    # authorize?: false — the system-only token read, which refuses any actor
    # itself; every admission rule above has passed for this user.
    case Accounts.complete_site_sso_sign_in(user.id, authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{} = signed_in} -> {:ok, signed_in}
      _failure -> {:error, :sign_in_failed}
    end
  end

  defp platform_admin?(user),
    do: user.role == :admin or RoleGrant.effective_role(user) == :admin

  # A membership-less account's global editor/admin role is a tier on the
  # default org. (Its `User.audiences` no longer grant anything anywhere: 1.0
  # removed that fallback, #1543.)
  defp legacy_access_elsewhere?(user, org_id) do
    org_id != Accounts.default_org_id() and
      RoleGrant.effective_role(user) in [:editor, :admin]
  end
end
