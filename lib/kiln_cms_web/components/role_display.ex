defmodule KilnCMSWeb.RoleDisplay do
  @moduledoc """
  One way to show a role on the console (#2142): the tier that applies **now**,
  up front, and — when a temporary grant (`KilnCMS.Accounts.RoleGrant`) is behind
  it — one line saying until when, and what it returns to.

  Before this, the standing role, a live grant and the account's status sat side
  by side as look-alike badges with nothing saying how they combine. The rule
  they combine by is `RoleGrant.effective_role/1` for a single row and
  `KilnCMS.Accounts.Scoping.tier_source/2` for a tier on a site, and this module
  renders from those rather than re-deriving it, so what the page says is what
  the policies decide.

  Two scopes, labelled so they are not confused:

    * `platform_access/1` — the account's platform tier (`User.role` and the
      user's own grant), for `KilnCMSWeb.AccountsLive`;
    * `site_access/2` — the tier on one site, whichever branch decides it
      (platform admin, membership, or the pre-#336 account role), for the team
      page, an account's sites, and the user's own settings.

  The expiry line is visible text beside the badge (and tied to it with
  `aria-describedby`), not a tooltip: a tooltip is invisible on touch and to
  many screen-reader flows, and the expiry is the part an admin most needs.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [badge: 1, time_left: 1]

  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMSWeb.RoleGrantForm

  @typedoc """
  A tier ready to render: what applies now, which branch decided it, the record
  whose grant columns govern it, and the changes ahead as live grants expire
  (`[]` when nothing is due to change).
  """
  @type access :: %{
          tier: atom() | nil,
          source: Scoping.tier_source(),
          record: map() | nil,
          changes: [Scoping.tier_change()]
        }

  @doc """
  A tier's display name — "Admin", "Editor", "Viewer" — translated. `:none` (and
  `nil`) read "No access". Strings are accepted for the tiers as stored.
  """
  @spec role_label(atom() | String.t() | nil) :: String.t()
  def role_label(:admin), do: pgettext("role", "Admin")
  def role_label(:editor), do: pgettext("role", "Editor")
  def role_label(:viewer), do: pgettext("role", "Viewer")
  def role_label(role) when role in ["admin", "editor", "viewer"], do: role_label(tier(role))
  def role_label(_none), do: pgettext("role", "No access")

  # The three stored tiers only — never an arbitrary string to atom.
  defp tier("admin"), do: :admin
  defp tier("editor"), do: :editor
  defp tier("viewer"), do: :viewer

  @doc """
  The label for the tier in `access`: `role_label/1`, except on a membership
  that grants nothing because its registration is awaiting approval or was
  rejected (#2251) — "Pending approval" or "Rejected", which say why there is
  no access rather than only that there is none.
  """
  @spec access_label(access()) :: String.t()
  def access_label(%{source: :member, record: %{status: :pending}}),
    do: pgettext("role", "Pending approval")

  def access_label(%{source: :member, record: %{status: :rejected}}),
    do: pgettext("role", "Rejected")

  def access_label(%{tier: tier}), do: role_label(tier)

  @doc "The tiers as `{label, tier}` select options, low to high."
  @spec role_options() :: [{String.t(), atom()}]
  def role_options, do: Enum.map(RoleGrant.tiers(), &{role_label(&1), &1})

  @doc """
  The account's **platform** tier: `RoleGrant.effective_role/1` on the user, and
  — while the user's own grant is live — the standing `role` it returns to.
  """
  @spec platform_access(map()) :: access()
  def platform_access(user) do
    tier = RoleGrant.effective_role(user)
    standing = Map.get(user, :role)

    changes =
      if RoleGrant.live?(user) and tier != standing,
        do: [{user.granted_role_expires_at, standing}],
        else: []

    %{tier: tier, source: :platform, record: user, changes: changes}
  end

  @doc """
  The user's tier on `org` — `Scoping.tier_source/2` and the changes ahead
  (`Scoping.tier_changes/2`). For the signed-in user's own page.
  """
  @spec site_access(map(), struct() | String.t() | nil) :: access()
  def site_access(user, org) do
    {tier, source, record} = Scoping.tier_source(user, org)
    %{tier: tier, source: source, record: record, changes: Scoping.tier_changes(user, org)}
  end

  @doc """
  `site_access/2` from a membership the page has just read (`nil`: none on
  `org`), so a page re-read after a write shows what the write left.
  """
  @spec site_access_for_membership(map(), struct() | String.t() | nil, map() | nil) :: access()
  def site_access_for_membership(user, org, membership) do
    {tier, source, record} = Scoping.tier_source_for_membership(user, org, membership)

    %{
      tier: tier,
      source: source,
      record: record,
      changes: Scoping.tier_changes_for_membership(user, org, membership)
    }
  end

  @doc "Whether the tier in `access` is due to change as a grant expires."
  @spec temporary?(access()) :: boolean()
  def temporary?(%{changes: [_ | _]}), do: true
  def temporary?(_access), do: false

  @doc """
  When the tier in `access` drops to viewer or no access — the end of console
  access — or `nil` if no change ahead does.
  """
  @spec console_access_ends_at(access()) :: DateTime.t() | nil
  def console_access_ends_at(%{changes: changes}) do
    Enum.find_value(changes, fn {at, tier} -> if tier in [:viewer, :none], do: at end)
  end

  @doc """
  The sentence explaining a temporary tier: "Admin is temporary: until <when>
  (<time left>), then Viewer." — or, when a second grant outlasts the first,
  "…, then Editor until <when>, then Viewer." `nil` when nothing is due to change.
  """
  @spec grant_text(access()) :: String.t() | nil
  def grant_text(%{tier: tier, changes: [{at, after_tier}]}) do
    gettext("%{role} is temporary: until %{when} (%{left}), then %{after}.",
      role: role_label(tier),
      when: RoleGrantForm.format(at),
      left: time_left(at),
      after: role_label(after_tier)
    )
  end

  def grant_text(%{tier: tier, changes: [{at, next_tier}, {next_at, after_tier} | _]}) do
    gettext(
      "%{role} is temporary: until %{when} (%{left}), then %{next} until %{next_when}, then %{after}.",
      role: role_label(tier),
      when: RoleGrantForm.format(at),
      left: time_left(at),
      next: role_label(next_tier),
      next_when: RoleGrantForm.format(next_at),
      after: role_label(after_tier)
    )
  end

  def grant_text(_access), do: nil

  @doc """
  The tier that applies now as one prominent badge after a scope label
  ("Platform:", "On this site:"), with the temporary-grant line under it when a
  grant governs. `:note` renders inline after the badge, for a qualifier such as
  "(platform admin)".
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :access, :map, required: true
  slot :note

  def role_summary(assigns) do
    assigns = assign(assigns, :grant_text, grant_text(assigns.access))

    ~H"""
    <div id={@id} class="space-y-0.5">
      <p class="flex flex-wrap items-center gap-1 text-sm">
        <span class="text-base-content/70">{@label}</span>
        <span id={"#{@id}-tier"} aria-describedby={@grant_text && "#{@id}-grant"}>
          <.badge variant={badge_variant(@access, @grant_text)}>
            {access_label(@access)}
          </.badge>
        </span>
        <span :if={@note != []} class="text-xs text-base-content/60">{render_slot(@note)}</span>
      </p>
      <p :if={@grant_text} id={"#{@id}-grant"} class="text-xs text-warning-ink">
        {@grant_text}
      </p>
    </div>
    """
  end

  defp badge_variant(_access, grant_text) when is_binary(grant_text), do: "warning"
  defp badge_variant(%{tier: tier}, _grant_text) when tier in [:none, nil], do: "outline"
  defp badge_variant(_access, _grant_text), do: "primary"
end
