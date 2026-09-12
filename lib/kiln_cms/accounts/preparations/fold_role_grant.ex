defmodule KilnCMS.Accounts.Preparations.FoldRoleGrant do
  @moduledoc """
  Presents a time-boxed tier grant as the record's `role`, on every read.

  Declared on the top-level `preparations` of `KilnCMS.Accounts.User` and
  `KilnCMS.Accounts.OrgMembership`, so it runs for *every* read action on both —
  `:read`, `:get_by_subject`, `:sign_in_with_password`, `:sign_in_with_api_key`,
  `:for_org`, a relationship load, an `Ash.get`. That breadth is the whole
  design: `role` on the actor struct is what a dozen `actor_attribute_equals(:role,
  :admin)` policies, `KilnCMS.Accounts.Scoping.effective_tier/2` and
  `KilnCMSWeb.LiveUserAuth.platform_admin?/1` read, and teaching each of those
  about `KilnCMS.Accounts.RoleGrant` separately would be a list to forget to add
  to — failing open, on the elevation axis. Folding once at the read means a
  grant stops applying the moment it expires, with nothing scheduled.

  Runs in `after_action` rather than at build time: a preparation's body executes
  when the query is *constructed* (once per `for_read`, potentially long before
  and repeatedly after execution), and this has to look at rows.

  ## What it does not do

  It does not *widen the select*. A read that narrowed away the grant columns
  gets no fold, because `RoleGrant.live?/1` answers `false` for anything that
  isn't a tier and a `DateTime` — the standing tier, which is the safe reading of
  absent data. `Ash.Query.ensure_selected/2` would buy nothing in exchange for
  two extra columns on every author-byline read: a caller who did not select
  `role` cannot act on it either.

  The pre-fold value is stashed as `:standing_role` metadata so the admin console
  can show "Editor · admin until Friday" from the same struct — see
  `KilnCMS.Accounts.RoleGrant.standing_role/1`.

  ## A folded record is not a base for a write

  Ash drops a submitted attribute that equals `changeset.data` — and it does so
  when the params are *cast*, before any change or validation module could put
  the row back. So building an update on a folded record silently loses the one
  write that matters most: promoting a temporary admin (`role: :editor`,
  `granted_role: :admin`) to a permanent one submits `role: :admin`, matches the
  folded `:admin` on the struct, is discarded as a no-op, and reports success
  while the column stays `:editor` — until the grant expires and demotes someone
  an admin had just promoted.

  A caller about to write a role therefore reads with
  `KilnCMS.Accounts.RoleGrant.unfolded/0`, which turns this preparation off for
  that query. Forgetting is not silent:
  `KilnCMS.Accounts.Validations.UnfoldedRecord` refuses a changeset built on a
  folded record.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts.RoleGrant

  @impl true
  def prepare(query, _opts, _context) do
    if RoleGrant.fold?(query) do
      Ash.Query.after_action(query, fn _query, records ->
        {:ok, Enum.map(records, &fold/1)}
      end)
    else
      query
    end
  end

  # `record.role in tiers()` is not belt-and-braces: on `KilnCMS.Accounts.User`
  # the standing `role` is behind the #183 field policy, so an anonymous author
  # byline read carries `%Ash.ForbiddenField{}` there — and writing a real tier
  # over it would disclose through the fold exactly what that policy withholds.
  #
  # `not RoleGrant.folded?/1` makes the fold idempotent. A second pass over an
  # already-folded struct (an `Ash.load/2` re-runs the read's preparations over
  # `:initial_data`) would otherwise stash the *granted* tier as `:standing_role`,
  # and `standing_role/1` would lie from then on — to `ClearRedundantRoleGrant`,
  # `NotLastAdmin` and `TemporaryRoleGrant` alike.
  defp fold(record) when is_struct(record) do
    if not RoleGrant.folded?(record) and Map.get(record, :role) in RoleGrant.tiers() and
         RoleGrant.live?(record) do
      record
      |> Ash.Resource.put_metadata(:standing_role, record.role)
      |> Map.put(:role, record.granted_role)
    else
      record
    end
  end

  # An aggregate-only or `Ash.Query.data_layer_query`-shaped result is not a
  # record; leave anything that isn't a resource struct alone.
  defp fold(other), do: other
end
