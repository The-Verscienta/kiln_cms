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
        auto_confirm_actions [:sign_in_with_magic_link, :reset_password_with_token]
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

    # The role is visible only to admins or the user themselves.
    field_policy :role do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(id == ^actor(:id))
    end

    # Everything else (id, email, timestamps) follows the resource read policy.
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

    # Set the public display name (used as the JSON-LD author byline). A user can
    # edit their own; admins can edit anyone's (via the policy bypass).
    update :update_profile do
      accept [:name]
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

    create :register_with_password do
      description "Register a new user with a email and password."

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
  end

  attributes do
    uuid_primary_key :id

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

    # RBAC role. Defaults to the least-privileged role so self-registration
    # can never grant elevated access; promote via a separate admin action.
    attribute :role, :atom do
      constraints one_of: [:admin, :editor, :viewer]
      default :viewer
      allow_nil? false
      public? true
    end
  end

  relationships do
    has_many :authored_pages, KilnCMS.CMS.Page do
      destination_attribute :author_id
    end

    has_many :authored_posts, KilnCMS.CMS.Post do
      destination_attribute :author_id
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
