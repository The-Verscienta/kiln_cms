defmodule KilnCMS.Accounts.User do
  @moduledoc """
  A user account. Authenticates via AshAuthentication (email + password) and
  carries the `role` attribute (`:admin`/`:editor`/`:viewer`) that the CMS
  resource policies authorize against.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  # The remember-me cookie's name, which is `__Host-`-prefixed exactly when the
  # session cookie is (#699). Resolved here rather than written as a literal
  # because the *read* path keys on this DSL value while the *write* path goes
  # through `KilnCMSWeb.AuthController`, and the two spelling it differently
  # would fail open — the browser would send nothing and no one would be
  # remembered. `KilnCMSWeb.SessionCookie` owns the rule for both cookies; see
  # its moduledoc for why the prefix cannot be unconditional.
  @remember_me_cookie KilnCMSWeb.SessionCookie.remember_me_key(
                        Application.compile_env(:kiln_cms, :secure_session_cookie, false)
                      )

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        # :register_with_sso — the OIDC provider has already verified the email
        # (the register change rejects unverified claims), so no second
        # confirmation loop.
        auto_confirm_actions [
          :sign_in_with_magic_link,
          :reset_password_with_token,
          :register_with_sso
        ]

        sender KilnCMS.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource KilnCMS.Accounts.Token
      signing_secret KilnCMS.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender KilnCMS.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      magic_link :magic_link do
        identity_field :email
        # Magic links sign in existing users only; new accounts are created via
        # password registration (which deliberately defaults to the :viewer
        # role). This avoids passwordless self-provisioning.
        registration_enabled? false
        # Require a click on the sign-in page (`magic_sign_in_route`) to
        # complete sign-in, so email link-scanners can't consume the one-time
        # token.
        require_interaction? true
        sender KilnCMS.Accounts.User.Senders.SendMagicLink
      end

      # "Remember me" on the sign-in form (#699). The token is a 30-day JWT, so
      # the cookie carrying it is a stronger credential than the session cookie
      # and gets the same `__Host-` treatment — see `KilnCMSWeb.SessionCookie`
      # and the `put_remember_me_cookie/3` override in `KilnCMSWeb.AuthController`.
      remember_me :remember_me do
        cookie_name @remember_me_cookie
        token_lifetime {30, :days}
      end

      # Third-party / headless read access. A key signs in as this user, so it
      # inherits the user's read scope; the relationship below is pre-filtered to
      # non-revoked, unexpired keys. See KilnCMS.Accounts.ApiKey.
      api_key :api_key do
        api_key_relationship :valid_api_keys
        api_key_hash_attribute :api_key_hash
      end

      # Enterprise SSO via any OpenID Connect provider (#331). Compile-gated
      # like invite-only mode: off by default so the lean install shows no SSO
      # button and exposes no OAuth routes; flip `config :kiln_cms, :sso_oidc,
      # enabled: true` (+ the OIDC_* env in runtime.exs) and recompile to
      # enable. Settings resolve at request time via SsoSecrets, so
      # credentials stay out of the build. See docs/sso.md.
      if Application.compile_env(:kiln_cms, [:sso_oidc, :enabled], false) do
        oidc :sso do
          client_id KilnCMS.Accounts.SsoSecrets
          client_secret KilnCMS.Accounts.SsoSecrets
          base_url KilnCMS.Accounts.SsoSecrets
          redirect_uri KilnCMS.Accounts.SsoSecrets
          # Stable linking by the provider's iss/sub — after the first
          # (verified-email) link, sign-in matches the stored identity, not
          # the email claim.
          identity_resource KilnCMS.Accounts.UserIdentity
          # First-time linking to an existing local account goes by the
          # provider's `email_verified` claim. Only point Kiln at an IdP that
          # reliably asserts email ownership (docs/sso.md); an unverified
          # match is rejected outright (`on_untrusted_email_match` default).
          trust_email_verified? true
        end
      end
    end
  end

  postgres do
    table "users"
    repo KilnCMS.Repo
  end

  # Field-level policies are defense-in-depth on top of the resource policies
  # above (which already restrict *which* user rows an actor can read). They
  # cap *which fields* are visible, so if user reads are ever broadened (e.g. an
  # editor picking an author), the role still isn't leaked. Non-public
  # attributes (`hashed_password`, `confirmed_at`) are never returned by reads
  # at all, so they need no field policy here.
  field_policies do
    # AshAuthentication needs every field during its own
    # sign-in/registration/reset flows.
    field_policy_bypass :*, AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Author PII (#183): the `author` relationship on CMS content is public, so
    # these fields would otherwise serialize via JSON:API `?include=author` /
    # GraphQL `author { ... }`. Restrict email, role and notification preferences
    # to admins or the user themselves, so anonymous and bearer-other API callers
    # only ever get the public byline (`id`, `name`). Internal byline/JSON-LD
    # loads run with `authorize?: false`, so they still read `name`.
    field_policy [
      :email,
      :role,
      :notify_on_review_request,
      :notify_on_publish,
      :notify_on_return_to_draft
    ] do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(id == ^actor(:id))
    end

    # Everything else (id, name, timestamps) follows the resource read policy.
    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    # Sign in via an API key (`api_key` strategy). Resolves the presented key to
    # its owning user and stamps `using_api_key?` metadata, which the content
    # policy reads to keep API-key actors read-only.
    read :sign_in_with_api_key do
      description "Authenticate a request presenting a valid API key."
      argument :api_key, :string, allow_nil?: false, sensitive?: true
      prepare AshAuthentication.Strategy.ApiKey.SignInPreparation
    end

    # Set the public display name (used as the JSON-LD author byline). A user can
    # edit their own; admins can edit anyone's (via the policy bypass).
    update :update_profile do
      accept [:name]
    end

    # Self-service workflow-notification preferences (issue #46). A user can
    # toggle their own; admins can edit anyone's via the policy bypass.
    update :update_notification_prefs do
      accept [:notify_on_review_request, :notify_on_publish, :notify_on_return_to_draft]
    end

    # Admin-only: assign a user's editorial role (authoring privilege) and the
    # consumer audiences (read access) they belong to. This is the single place
    # access is granted — self-registration always lands on `:viewer` with no
    # audiences. See KilnCMS.CMS.Audiences and the content read policy.
    update :manage_access do
      accept [:role, :audiences, :editable_types, :readable_types, :field_grants]
      # The shape validation inspects the whole map — no atomic expression.
      require_atomic? false
      validate KilnCMS.Accounts.Validations.FieldGrantsShape

      # Every socket authorizes once, at connect and join, and never again — so
      # a demotion or a narrowed scope left the live ones holding the grant they
      # had (#675). Dropping them makes the next message prove it again.
      change {KilnCMS.Accounts.Changes.EvictSessions, reason: :access_changed}
    end

    # Billing-derived read entitlements (#337 Phase 2). Written only by
    # `KilnCMS.Billing.Entitlements` — the declarative recompute — as a system
    # call. NOT a general audience editor: `:manage_access` above remains the
    # admin lever and is untouched.
    update :sync_billing_audiences do
      description "Apply billing-derived audiences (system-only)."
      accept [:audiences]
      # The guard change runs in Elixir — no atomic expression.
      require_atomic? false
      change KilnCMS.Accounts.Changes.SyncBillingAudiences

      # Audiences are the read axis, so a lapsed subscription narrows what a
      # live GraphQL subscription may see (#675).
      change {KilnCMS.Accounts.Changes.EvictSessions, reason: :audiences_changed}
    end

    # GDPR Art. 17 erasure (#212). Admin-only. Scrubs PII from the account and
    # revokes tokens + anonymizes audit-event actors, while keeping the row and
    # content/version history (audit retention — #219). See
    # KilnCMS.Accounts.Changes.AnonymizeUser and docs/data-flows.md.
    update :anonymize do
      description "Scrub personal data from a user while retaining audit history."
      require_atomic? false
      accept []
      change KilnCMS.Accounts.Changes.AnonymizeUser

      # The erasure revokes tokens, which stops new connections; the live ones
      # had to be dropped too (#675).
      change {KilnCMS.Accounts.Changes.EvictSessions, reason: :anonymized}
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      # Declared here rather than only on `:sign_in_with_token` because this is
      # the action the sign-in form is built from, and
      # `Components.Helpers.remember_me_field/1` looks for the preparation on
      # *this* action to decide whether to render the checkbox at all (#699).
      argument :remember_me, :boolean do
        description "Whether to issue a long-lived remember-me token."
        allow_nil? true
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      # Per-account budget on top of the per-IP `:auth` bucket (#478) — an
      # attacker rotating IPs gets a fresh window per address otherwise.
      # Refuses with the same `AuthenticationFailed` a wrong password produces.
      prepare KilnCMS.Accounts.Preparations.ThrottleSignIn

      # Mints the remember-me token when the box is ticked. On the LiveView path
      # it deliberately does nothing here: `sign_in_tokens_enabled?` is on, so
      # the form sets `skip_remember_me_token_generation` and forwards the flag
      # to `:sign_in_with_token` instead, which is where the token is actually
      # minted. Keeping it on both is what makes the direct (non-LiveView) POST
      # to `/auth/user/password/sign_in` work as well.
      prepare AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end

      metadata :remember_me, :map do
        description "The remember-me token, cookie name and lifetime, when requested."
        allow_nil? true
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # The LiveView sign-in form carries the ticked checkbox across this
      # exchange as a query param rather than minting on the password action,
      # so this is where the remember-me token is actually issued (#699).
      argument :remember_me, :boolean do
        description "Whether to issue a long-lived remember-me token."
        allow_nil? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation
      prepare AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end

      metadata :remember_me, :map do
        description "The remember-me token, cookie name and lifetime, when requested."
        allow_nil? true
      end
    end

    # OIDC SSO sign-in/registration (#331): upsert by verified email. An
    # existing account (matched on :unique_email) signs in AS-IS — role,
    # audiences, and display name untouched (upsert_fields is just [:email]);
    # a new account lands as :viewer like password self-registration. The
    # change enforces verified-email-only and invite-only mode.
    create :register_with_sso do
      description "Register or sign in a user from an OIDC identity."

      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false, sensitive?: true

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      change KilnCMS.Accounts.Changes.RegisterWithSso
      # Persist the provider's iss/sub link (UserIdentity) and mint the session
      # token — both required by the OAuth2/OIDC strategy machinery.
      change AshAuthentication.Strategy.OAuth2.IdentityChange
      change AshAuthentication.GenerateTokenChange
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      # Bounded per client address (#724). The form submits over `/live`, so it
      # passes no router pipeline and no plug can reach it — one websocket
      # replaying `submit` was unlimited account creation.
      change KilnCMS.Accounts.Changes.ThrottleRegistration

      # Invite-only mode: reject self-registration when
      # `config :kiln_cms, :registration_enabled` is false.
      validate KilnCMS.Accounts.Validations.RegistrationEnabled

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    # Written out rather than generated, so a per-address budget can go in front
    # of it (#724). `MagicLink.Transformer` builds this action only when the
    # resource does not already define it, and what it builds is exactly the two
    # entities below — one argument and its own preparation. Ours runs first.
    read :request_magic_link do
      description "Send a magic sign-in link to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      prepare KilnCMS.Accounts.Preparations.ThrottleMagicLink
      prepare AshAuthentication.Strategy.MagicLink.RequestPreparation
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # Creates a reset token and invokes the relevant senders — behind a
      # per-address budget (#724), because this form submits over `/live` too.
      # A generic action has no `prepare`/`change` hook, so the charge wraps the
      # run rather than sitting beside it.
      run {KilnCMS.Accounts.ThrottledPasswordResetRequest, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    # Passkey sign-in (#331): returns the verified account with its session
    # token minted (metadata), mirroring the built-in strategies. Performs NO
    # authentication itself — only KilnCMS.Accounts.WebAuthn.authenticate/2
    # calls it (authorize?: false), after Wax verified the WebAuthn assertion.
    read :sign_in_with_passkey do
      description "Completes a WebAuthn-verified sign-in (system-only)."
      argument :user_id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:user_id))
      prepare KilnCMS.Accounts.Preparations.PasskeySessionToken
    end

    update :reset_password_with_token do
      # `ForgiveSignInThrottle` runs an `after_action` hook (it needs the saved
      # record's email), which an atomic update has no place to put.
      require_atomic? false

      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # Holding the emailed reset token proves the account is yours, so it
      # releases the per-account sign-in budget (#478) — otherwise the remedy
      # the throttle's own alert mail recommends leaves the owner still locked.
      change KilnCMS.Accounts.Changes.ForgiveSignInThrottle
    end

    # --- Two-factor authentication (TOTP) self-service (issue #331) ---

    # Begin enrolment: mint a fresh secret into `totp_pending_secret`, entirely
    # separate from whatever `totp_secret`/`totp_confirmed_at` currently hold.
    # The caller (the user themselves) reads back `totp_pending_secret` to show
    # the authenticator QR/URI.
    #
    # #754: this used to write straight into `totp_secret` and null
    # `totp_confirmed_at` in the same call — one unauthenticated, unthrottled
    # request from any session on the account turned 2FA off. Staging into a
    # separate attribute means `:setup_totp` cannot weaken an already-confirmed
    # account by itself: nothing about the live factor changes until
    # `:confirm_totp` proves the *new* secret and promotes it. That is also
    # what makes re-enrolment self-service for someone who lost their device —
    # they hold a session (from a recovery-code sign-in) but no code to prove,
    # and this asks for none.
    update :setup_totp do
      description "Start 2FA enrolment by generating a new TOTP secret."
      accept []
      require_atomic? false
      change set_attribute(:totp_pending_secret, &KilnCMS.Accounts.Totp.generate_secret/0)
    end

    # Finish enrolment by proving a code from the *pending* secret, then
    # promote it to `totp_secret` and stamp `totp_confirmed_at` — only then is
    # 2FA actually enforced at sign-in. Also mints the one-time recovery-code
    # set (#331 phase 2) — plaintext codes ride back once as `:recovery_codes`
    # metadata; only hashes are stored.
    update :confirm_totp do
      description "Confirm 2FA enrolment with a code from the authenticator app."
      accept []
      require_atomic? false

      argument :code, :string, allow_nil?: false, sensitive?: true

      # Proof of the OUTGOING factor, required only when promoting *over* an
      # already-confirmed secret and not from a recovery-code session (#786). A
      # first enrolment leaves both unset. `recovery_login?` is set by the caller
      # from server-side session provenance, never client input.
      argument :current_code, :string, allow_nil?: true, sensitive?: true
      argument :recovery_login?, :boolean, allow_nil?: false, default: false

      # Budgeted like the other two (#727). Not because a stolen-session
      # attacker can grind this into a bypass — they would have to have called
      # `:setup_totp` themselves first, in which case they already know the
      # code and have nothing to guess — but because a *legitimate* enrolment
      # in progress is itself something worth budgeting: while the real owner
      # holds an unconfirmed pending secret waiting to be typed in, a second,
      # attacker-held session on the same account could otherwise grind the
      # 6-digit space for that same pending secret and confirm it out from
      # under them. It also budgets grinding of `current_code` below.
      change KilnCMS.Accounts.Changes.ThrottleSecondFactor
      validate {KilnCMS.Accounts.Validations.ValidTotpCode, secret_field: :totp_pending_secret}
      # Replacing a live factor needs the outgoing code (or a recovery-code
      # session) — a bare setup_totp+confirm_totp can no longer swap the secret
      # silently out from under the owner (#786).
      validate KilnCMS.Accounts.Validations.RequireCurrentFactorForReplacement
      change KilnCMS.Accounts.Changes.PromotePendingTotpSecret
      change set_attribute(:totp_confirmed_at, &DateTime.utc_now/0)
      change KilnCMS.Accounts.Changes.GenerateRecoveryCodes
    end

    # Replace the recovery-code set — requires a current authenticator code, so
    # an attacker on a stolen session can't mint themselves backup codes without
    # guessing it, and gets five guesses per fifteen minutes to try (#727).
    # Unused codes from the previous set stop working immediately.
    update :regenerate_totp_recovery_codes do
      description "Mint a fresh 2FA recovery-code set (invalidates the old one)."
      accept []
      require_atomic? false

      argument :code, :string, allow_nil?: false, sensitive?: true

      # Above the validation on purpose — see the change's moduledoc. A wrong
      # code is the only one worth charging, and by the time the validation has
      # rejected it there is no hook left to charge from.
      change KilnCMS.Accounts.Changes.ThrottleSecondFactor
      validate KilnCMS.Accounts.Validations.ValidTotpCode
      change KilnCMS.Accounts.Changes.GenerateRecoveryCodes
    end

    # Second-factor fallback at the sign-in gate (#331): validate-and-burn one
    # recovery code atomically. Called pre-authentication as a system action
    # (`authorize?: false` from `TwoFactorController`) — the user isn't signed
    # in until this succeeds.
    update :consume_totp_recovery_code do
      description "Use (and invalidate) one 2FA recovery code."
      accept []
      require_atomic? false

      argument :code, :string, allow_nil?: false, sensitive?: true

      change KilnCMS.Accounts.Changes.ConsumeRecoveryCode
    end

    # Turn 2FA off — requires a current code, and that code is now budgeted, so
    # an attacker on a stolen session can't remove the second factor by grinding
    # six digits at socket speed either (#727). Five attempts per account per
    # fifteen minutes, shared with the sign-in prompt so the two can't be spent
    # independently. `:setup_totp` above no longer has a door of its own to
    # turn the factor off (#754) — it cannot touch `totp_confirmed_at` at all.
    #
    # Also drops any staged `totp_pending_secret`, so an abandoned re-enrolment
    # (started, never confirmed) doesn't outlive the factor it was replacing.
    update :disable_totp do
      description "Disable 2FA (requires a current code)."
      accept []
      require_atomic? false

      argument :code, :string, allow_nil?: false, sensitive?: true

      change KilnCMS.Accounts.Changes.ThrottleSecondFactor
      validate KilnCMS.Accounts.Validations.ValidTotpCode
      change set_attribute(:totp_secret, nil)
      change set_attribute(:totp_confirmed_at, nil)
      change set_attribute(:totp_recovery_hashes, [])
      change set_attribute(:totp_pending_secret, nil)
    end
  end

  policies do
    # Let AshAuthentication run its sign-in/registration/reset machinery.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Admins manage all users — listing accounts and assigning roles (RBAC
    # promotion happens here, never via self-registration).
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # A signed-in user may read their own record and change their own password.
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:change_password) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_notification_prefs) do
      authorize_if expr(id == ^actor(:id))
    end

    # 2FA is strictly self-service: a user manages the second factor on their own
    # account only (the admin bypass above still lets an operator intervene).
    # `:consume_totp_recovery_code` runs pre-auth as a system call
    # (`authorize?: false` from the 2FA gate), so it needs no anonymous grant here.
    policy action([
             :setup_totp,
             :confirm_totp,
             :disable_totp,
             :regenerate_totp_recovery_codes
           ]) do
      authorize_if expr(id == ^actor(:id))
    end

    # Erasure is an operator action — admins only (covered by the admin bypass
    # above; this makes the intent explicit and forbids everyone else).
    policy action(:anonymize) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # The passkey sign-in completion mints a session token — system-only
    # (`authorize?: false` from WebAuthn.authenticate/2 after assertion
    # verification). This filter-forbids ordinary authorized callers; the
    # admin bypass above would still pass, so the PasskeySessionToken
    # preparation ALSO refuses any actor-carrying call — no authorized path
    # (admin included) can mint a token for another account.
    policy action(:sign_in_with_passkey) do
      forbid_if always()
    end

    # Assigning the editorial role and consumer audiences is an admin action —
    # never self-service (a user must not grant themselves access). Covered by
    # the admin bypass above; explicit here to forbid everyone else.
    policy action(:manage_access) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Billing entitlements are system-only: only `KilnCMS.Billing.Entitlements`
    # (running `authorize?: false`) may reach this. As with
    # `:sign_in_with_passkey`, the admin bypass above would still pass a
    # `forbid_if`, so the SyncBillingAudiences change ALSO refuses any
    # actor-carrying call — no authorized path grants an entitlement by hand.
    policy action(:sync_billing_audiences) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    # Must stay `public?` — AshAuthentication requires the password identity field
    # to be public. It is kept off the public author byline by the field policy
    # below (#183), which restricts email reads to admins / the user themselves.
    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    # Public display name — used as the JSON-LD author on content this user
    # authored. Optional; falls back to no author when blank.
    attribute :name, :string do
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :confirmed_at, :utc_datetime_usec

    # Set when the account has been scrubbed via the `:anonymize` erasure action
    # (#212). Non-nil marks a tombstoned account (email/name no longer personal).
    attribute :anonymized_at, :utc_datetime_usec do
      public? true
    end

    # RBAC role. Defaults to the least-privileged role so self-registration
    # can never grant elevated access; promote via a separate admin action.
    # `public?` for the API schema, but never leaked on the author byline: the
    # field policy below restricts role reads to admins / the user themselves
    # (#183), so anonymous and bearer-other API callers can't read it.
    attribute :role, :atom do
      constraints one_of: [:admin, :editor, :viewer]
      default :viewer
      allow_nil? false
      public? true
    end

    # Consumer-facing access tiers this user belongs to (the *read* axis, kept
    # separate from `role` — see KilnCMS.CMS.Audiences). Gates which published,
    # audience-restricted content the user may read. Empty by default, so a fresh
    # account sees only `:public` content until an admin grants audiences via
    # `:manage_access`. Not `public?` — it's access-control data, never part of
    # the author byline, and the content read policy reads it off the actor
    # struct regardless of API visibility.
    attribute :audiences, {:array, :atom} do
      constraints items: [one_of: KilnCMS.CMS.Audiences.all()]
      default []
      allow_nil? false
      public? false
    end

    # Granular authoring scope (#332): the content types this editor may
    # create/update. Empty (the default) means no restriction — author any type,
    # so existing editors are unchanged; a non-empty list scopes the editor to
    # those types (e.g. `["post"]`). Admins ignore it (they bypass the content
    # authoring policies). Access-control config, so `public? false` like
    # `audiences`; set by an admin via `:manage_access`.
    attribute :editable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    # Granular RBAC read axis (#332 phase 2): the content types where an editor
    # sees non-published content (drafts/in-review/archived). Empty (default) =
    # all types — editors are unchanged; non-empty restricts editorial
    # visibility to those types (published content stays readable like any
    # signed-in consumer). Same conventions as `editable_types` above; the
    # per-org override lives on `OrgMembership` (see KilnCMS.Accounts.Scoping).
    attribute :readable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    # Per-field write grants (#332 slice 3): content-type name → the attribute
    # names the editor may change on existing documents of that type
    # (`%{"post" => ["title", "blocks"]}`). No entry for a type = no per-field
    # restriction (the default). Enforced by
    # KilnCMS.CMS.Changes.EnforceFieldGrants; per-org override on
    # `OrgMembership` (see KilnCMS.Accounts.Scoping.field_grant/3).
    attribute :field_grants, :map do
      default %{}
      allow_nil? false
      public? false
    end

    # Per-user workflow-notification preferences (issue #46). Opt-out model:
    # every notification defaults on, and a user can mute each event for their
    # own account via `:update_notification_prefs`. `KilnCMS.Notifications`
    # honours these before enqueuing mail.
    # Personal account settings — kept off the public author byline by the field
    # policy below (#183), which restricts these to admins / the user themselves.
    # Edited via the self-service `:update_notification_prefs` action.
    attribute :notify_on_review_request, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :notify_on_publish, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :notify_on_return_to_draft, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # Two-factor (TOTP) secret and enrolment timestamp (issue #331). The raw
    # secret is stored as bytea; `sensitive?` keeps it out of inspect/logs and
    # `public? false` keeps both off every API surface — they're read only
    # internally (by the sign-in gate and the owner's enrolment UI). 2FA is
    # "enabled" iff `totp_confirmed_at` is set.
    attribute :totp_secret, :binary do
      sensitive? true
      public? false
    end

    attribute :totp_confirmed_at, :utc_datetime_usec do
      public? false
    end

    # A staged secret from `:setup_totp`, not yet proven (#754). Lets
    # enrolment run without touching `totp_secret`/`totp_confirmed_at` until
    # `:confirm_totp` proves the caller holds it and promotes it — so
    # generating one can never by itself weaken or disable an existing,
    # confirmed factor.
    attribute :totp_pending_secret, :binary do
      sensitive? true
      public? false
    end

    # SHA-256 hashes of the unused one-time recovery codes (#331 phase 2);
    # plaintext is shown once at generation and never stored. Managed only by
    # the dedicated actions (generate / consume / disable).
    attribute :totp_recovery_hashes, {:array, :string} do
      allow_nil? false
      default []
      sensitive? true
      public? false
      writable? false
    end
  end

  relationships do
    has_many :authored_pages, KilnCMS.CMS.Page do
      destination_attribute :author_id
    end

    has_many :authored_posts, KilnCMS.CMS.Post do
      destination_attribute :author_id
    end

    # The `api_key` strategy trusts this relationship to be *valid* keys only, so
    # revoked/expired keys are filtered out here (not at sign-in time).
    has_many :valid_api_keys, KilnCMS.Accounts.ApiKey do
      filter expr(is_nil(revoked_at) and expires_at > now())
    end

    # Org memberships (epic #336): which organizations this (global) user belongs
    # to, and their per-org role. The authoring policies still read `role` off the
    # user for now; a later PR moves the effective-role source onto the membership.
    has_many :org_memberships, KilnCMS.Accounts.OrgMembership do
      destination_attribute :user_id
    end
  end

  aggregates do
    count :authored_page_count, :authored_pages
    count :authored_post_count, :authored_posts
  end

  identities do
    identity :unique_email, [:email]
  end
end
