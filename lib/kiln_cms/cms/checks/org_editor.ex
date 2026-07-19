defmodule KilnCMS.CMS.Checks.OrgEditor do
  @moduledoc """
  Matches an actor whose **effective tier on the request's org** is `:editor`
  or `:admin` (#419 — per-org capability tiers). The org-scoped counterpart
  of `actor_attribute_equals(:role, :editor)` grants — see `OrgAdmin` for the
  resolution semantics.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.Scoping

  @impl Ash.Policy.Check
  def describe(_opts), do: "an editor (or admin) of the request's organization"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{subject: subject}, _opts) do
    Scoping.effective_tier(actor, subject) in [:editor, :admin]
  end
end
