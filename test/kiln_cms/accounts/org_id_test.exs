defmodule KilnCMS.Accounts.OrgIdTest do
  @moduledoc """
  `KilnCMS.Accounts.org_id/1` (#527) — the single answer to "what org id is
  behind this thing", replacing ten private copies that disagreed on `nil`.

  The disagreement was not cosmetic: several raised a `FunctionClauseError` on
  it, others fell back to the sole org, and one had no `is_binary` guard at all.
  What is NOT in the contract matters just as much — most of those copies
  matched `%{id: id}` loosely, which accepts a `User`, a `Page` or a socket and
  hands its id downstream as a tenant, where it surfaces as an empty registry
  rather than an error.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts

  test "unwraps an organization struct" do
    org = Accounts.get_organization!(Accounts.default_org_id(), authorize?: false)
    assert Accounts.org_id(org) == org.id
  end

  test "passes a bare id through" do
    id = Accounts.default_org_id()
    assert Accounts.org_id(id) == id
  end

  test "resolves nil to the default org rather than raising" do
    assert Accounts.org_id(nil) == Accounts.default_org_id()
  end

  # Nothing else is an org. These raise rather than resolving to the default,
  # because a struct that merely has an `id` is not a tenant — reading one as
  # such produces an empty result set, not a failure, which is the harder bug.
  test "raises on anything that isn't an organization" do
    # A `%User{}` has a binary `id` and nothing else to distinguish it — exactly
    # the shape the loose `%{id: id}` copies happily read as a tenant.
    user = %KilnCMS.Accounts.User{id: Ecto.UUID.generate()}

    assert_raise FunctionClauseError, fn -> Accounts.org_id(user) end
    assert_raise FunctionClauseError, fn -> Accounts.org_id(%{id: Ecto.UUID.generate()}) end
    assert_raise FunctionClauseError, fn -> Accounts.org_id(%{}) end
    assert_raise FunctionClauseError, fn -> Accounts.org_id(:unset) end
  end
end
