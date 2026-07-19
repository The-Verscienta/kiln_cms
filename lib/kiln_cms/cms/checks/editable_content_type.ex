defmodule KilnCMS.CMS.Checks.EditableContentType do
  @moduledoc """
  Matches an editor permitted to author *this* content type (granular RBAC, #332).

  The editor's effective `editable_types` scope — their `OrgMembership` for the
  request's org, falling back to the `KilnCMS.Accounts.User` column (see
  `KilnCMS.Accounts.Scoping`) — names the content types they may create/update.
  An **empty** scope means no restriction — author any type (the default,
  backward-compatible); a non-empty scope restricts the editor to the named
  types (e.g. `["post"]` for a blog editor who can't touch pages). Admins
  bypass this entirely (the content policies bypass on `:admin`); viewers and
  anonymous actors never match.

  The name compared is the resource's `__kiln_content_type__/0`. Every dynamic
  (D17) type shares the `entry` storage key, so `["entry"]` scopes an editor to
  all admin-defined types as a group — per-dynamic-type scoping is a later phase.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.Scoping

  @impl Ash.Policy.Check
  def describe(_opts), do: "an editor permitted to author this content type"

  @impl Ash.Policy.SimpleCheck
  def match?(%{} = actor, %{resource: resource, subject: subject}, _opts) do
    # Per-org tiers (#419): the EFFECTIVE tier gates authoring, so an
    # org-granted editor passes here even when their global role is viewer
    # (admins bypass upstream, but effective admins pass unrestricted too).
    case Scoping.effective_tier(actor, subject) do
      :admin ->
        true

      :editor ->
        type = KilnCMS.CMS.ContentTypes.type_name(resource)
        Scoping.permitted?(actor, subject, :editable_types, type)

      _ ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
