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

      remember_me :remember_me

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
      accept [:role, :audiences, :editable_types]
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

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
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

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
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

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    update :reset_password_with_token do
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
    end

    # --- Two-factor authentication (TOTP) self-service (issue #331) ---

    # Begin enrolment: mint a fresh secret (unconfirmed). The caller (the user
    # themselves) reads back `totp_secret` to show the authenticator QR/URI.
    update :setup_totp do
      description "Start 2FA enrolment by generating a new TOTP secret."
      accept []
      require_atomic? false
      change set_attribute(:totp_secret, &KilnCMS.Accounts.Totp.generate_secret/0)
      change set_attribute(:totp_confirmed_at, nil)
    end

    # Finish enrolment by proving a code from the new secret; only then is 2FA
    # actually enforced at sign-in.
    update :confirm_totp do
      description "Confirm 2FA enrolment with a code from the authenticator app."
      accept []
      require_atomic? false

      argument :code, :string, allow_nil?: false, sensitive?: true

      validate KilnCMS.Accounts.Validations.ValidTotpCode
      change set_attribute(:totp_confirmed_at, &DateTime.utc_now/0)
    end

    # Turn 2FA off — requires a current code, so a walk-up attacker on an open
    # session still can't remove the second factor.
    update :disable_totp do
      description "Disable 2FA (requires a current code)."
      accept []
      require_atomic? false

      argument :code, :string, allow_nil?: false, sensitive?: true

      validate KilnCMS.Accounts.Validations.ValidTotpCode
      change set_attribute(:totp_secret, nil)
      change set_attribute(:totp_confirmed_at, nil)
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
    policy action([:setup_totp, :confirm_totp, :disable_totp]) do
      authorize_if expr(id == ^actor(:id))
    end

    # Erasure is an operator action — admins only (covered by the admin bypass
    # above; this makes the intent explicit and forbids everyone else).
    policy action(:anonymize) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Assigning the editorial role and consumer audiences is an admin action —
    # never self-service (a user must not grant themselves access). Covered by
    # the admin bypass above; explicit here to forbid everyone else.
    policy action(:manage_access) do
      authorize_if actor_attribute_equals(:role, :admin)
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
