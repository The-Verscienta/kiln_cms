defmodule KilnCMS.CMS.SiteSessionPolicy do
  @moduledoc """
  How long a signed-in browser may sit idle on this site before it is signed
  out (#2246): `idle_timeout_minutes` for everyone and, optionally, a shorter
  `admin_idle_timeout_minutes` for the site's administrators. Both `nil` (the
  default, and a site with no row) means no idle timeout. Values run from 10
  minutes to a day; the administrators' timeout may not be longer than
  everyone's when both are set.

  `KilnCMS.Accounts.IdleTimeout` enforces it. The site decides: there is no
  operator ceiling (ADR 0018 only constrains a site against one), and a row
  that cannot be read fails open — no timeout — and is logged.

  Two columns are not accepted from input:

    * `policy_changed_at` — set on every save. Idle time is measured from no
      earlier than it, so turning the timeout on or shortening it never signs
      anyone out for inactivity that happened before.
    * `sessions_revoked_at` — the watermark of the site's last "sign out
      everyone" (`sign_out_all`), written only by that action. A session
      signed in before it and next seen on this site's host is signed out.

  One row per organization, created lazily, admin-only to read and write: the
  `KilnCMS.CMS.SitePasswordPolicy` shape, except that it is never deleted
  (`:destroy` is refused): it carries the watermark. The idle check reads it as
  `KilnCMS.OrgSettings.system(:accounts)`; `system_actions:` admits `read` and
  nothing else.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_session_policy",
    accept: [:idle_timeout_minutes, :admin_idle_timeout_minutes],
    upsert_fields: [:idle_timeout_minutes, :admin_idle_timeout_minutes, :policy_changed_at],
    save_changes: [KilnCMS.CMS.Changes.StampSessionPolicyChange],
    read: :admin,
    admin_columns: [:idle_timeout_minutes, :admin_idle_timeout_minutes, :updated_at],
    system_actions: [read: :accounts]

  @min_minutes 10
  @max_minutes 1440

  @doc "The shortest accepted timeout, in minutes."
  @spec min_minutes() :: pos_integer()
  def min_minutes, do: @min_minutes

  @doc "The longest accepted timeout, in minutes (a day)."
  @spec max_minutes() :: pos_integer()
  def max_minutes, do: @max_minutes

  actions do
    # The watermark of "sign out everyone", written by `sign_out_all` below and
    # nowhere else (refused to every caller by name in the policies).
    create :record_sessions_revoked do
      accept []
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:sessions_revoked_at]
      argument :at, :utc_datetime_usec, allow_nil?: false
      change set_attribute(:sessions_revoked_at, arg(:at))
    end

    # Sign out every browser signed in on this site, except — when asked — the
    # caller's own. See `KilnCMS.Accounts.SignOutAll`. Returns how many
    # sessions were signed out.
    action :sign_out_all, :integer do
      description "Sign out every browser session on this site."

      argument :except_session_jti, :string, sensitive?: true

      run KilnCMS.Accounts.SignOutAll
    end
  end

  validations do
    validate {KilnCMS.CMS.Validations.AdminIdleTimeoutNotLonger, []},
      on: [:create, :update],
      where: [action_is([:save, :update])]
  end

  changes do
    # Bust the cached policy on every node and tell the site's open pages,
    # once the write commits — on a save, a reset and a sign-out-everyone.
    change KilnCMS.CMS.Changes.SessionPolicyChanged, on: [:create, :update, :destroy]
  end

  policies do
    # An org admin act. The OrgSettings write policy covers creates, updates
    # and destroys; a generic action is none of those, so it is named here.
    policy action(:sign_out_all) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    # Only `sign_out_all` writes the watermark, with its own authorization
    # already decided; every caller of the action itself is refused.
    policy action(:record_sessions_revoked) do
      forbid_if always()
    end

    # The row holds the watermark of the last "sign out everyone"; deleting
    # it would let every session it caught back in. Turning the timeout off
    # saves `nil`s instead, so the macro's `:destroy` is refused to everyone.
    policy action(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    attribute :idle_timeout_minutes, :integer do
      public? true
      constraints min: @min_minutes, max: @max_minutes
    end

    attribute :admin_idle_timeout_minutes, :integer do
      public? true
      constraints min: @min_minutes, max: @max_minutes
    end

    attribute :policy_changed_at, :utc_datetime_usec do
      public? true
      writable? true
    end

    attribute :sessions_revoked_at, :utc_datetime_usec do
      public? true
      writable? true
    end
  end
end
