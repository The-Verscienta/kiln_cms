defmodule KilnCMS.CMS.SiteAdminAllowlist do
  @moduledoc """
  The networks a site's console and sign-in may be reached from (#2248): IPv4
  and IPv6 addresses and ranges, such as an office or a VPN. An empty list (the
  default, and a site with no row) means off: every network is admitted.

  `restrict_sign_in` (#2493, on by default) says whether the list also gates
  sign-in: `/sign-in` and the rest of the sign-in family, and the headless
  `POST /api/auth/sign_in`. Turned off, members sign in from anywhere while the
  console, `/setup` and their live sessions stay behind the list. It has no
  effect while the list is empty.

  `KilnCMS.Security.AdminAllowlist` reads it for the gates; see that module for
  what is covered, what it costs and why it fails closed. The site decides:
  there is no operator ceiling (ADR 0018 constrains a site against one only
  where a looser value costs the deployment, and a looser list costs only the
  site). The operator's levers are a way back in, never a ceiling:
  `operator_override` below, run by `KilnCMS.Release.admin_allowlist/1`, and
  the `KILN_ADMIN_ALLOWLIST_DISABLED` switch.

  ## Writing it

  `:save` (and `:update`) normalise every entry (`Cidr.allowable/1`: masked,
  compressed, no loopback, nothing wider than `/8` or `/16`), drop duplicates
  and refuse more than 100. Then `KilnCMS.CMS.Changes.RefuseAdminLockout`
  refuses a non-empty list that does not admit the address of the person
  saving it, or that it cannot check that against. There is no "confirm
  anyway": a list that excludes you is an immediate, total lock-out.

  Every person's save records `admin_allowlist_changed` (counts and on/off,
  never the entries). Turning it off is saving `[]`, so off has one path and
  one audit trail; `:destroy` is refused to everyone.

  ## The operator's override

  `operator_override` only widens an active list (`add:`) or empties it
  (`clear: true`), so it can never lock anyone out, and records
  `admin_allowlist_overridden` in its transaction. Adding to a list that is
  off is refused: that would turn the list on from a shell, and lock out
  every admin. Only the `:operator` system actor may run it; an admin is
  refused.

  Not an API surface: absent from JSON:API, GraphQL and MCP.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_admin_allowlist",
    accept: [:cidrs, :restrict_sign_in],
    save_changes: [
      KilnCMS.CMS.Changes.NormalizeAdminAllowlist,
      KilnCMS.CMS.Changes.RefuseAdminLockout
    ],
    read: :admin,
    audit: {:change, KilnCMS.CMS.Changes.RecordAdminAllowlistChange},
    admin_columns: [:cidrs, :restrict_sign_in, :updated_at],
    system_actions: [read: [:admin_allowlist, :operator], operator_override: :operator]

  @max_entries 100

  @doc "The most entries a list may hold."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  actions do
    update :operator_override do
      description "Widen or empty the list from the server (KilnCMS.Release.admin_allowlist/1)."
      accept []
      require_atomic? false

      argument :add, :string
      argument :clear, :boolean, default: false

      # Re-read and lock the row in the transaction: the list is widened from
      # what is stored now, so a console save that committed after the caller
      # read the row is not overwritten.
      change get_and_lock_for_update()
      change KilnCMS.CMS.Changes.OperatorOverrideAdminAllowlist
    end
  end

  changes do
    # Bust the compiled list on every node and tell the site's open console and
    # sign-in pages, once the write commits.
    change KilnCMS.CMS.Changes.AdminAllowlistChanged, on: [:create, :update]
  end

  policies do
    # The way back in from the server, and nothing else. ANDed with the
    # OrgSettings write policy, which admits an org admin for any update: this
    # one refuses everyone but the operator.
    policy action(:operator_override) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: [:operator], action: [:operator_override]}
    end

    # Off is `save(cidrs: [])`: one path, one audit trail.
    policy action(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    attribute :cidrs, {:array, :string} do
      allow_nil? false
      default []
      public? true
      # The cap users see is enforced (after de-duplication, with its own
      # message) by `NormalizeAdminAllowlist`; this is only a backstop, set
      # well above it so Ash's generic message never pre-empts that one.
      constraints max_length: @max_entries * 10, items: [max_length: 64]
    end

    # Does the list gate sign-in too (#2493)? On by default, so a site that
    # had a list before this setting existed keeps what it had. `:save` is an
    # upsert, and a defaulted column is always carried on its create side: a
    # save that leaves this out resets it to `true`. Every writer passes both.
    attribute :restrict_sign_in, :boolean do
      allow_nil? false
      default true
      public? true
    end
  end
end
