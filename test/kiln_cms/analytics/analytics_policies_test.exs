defmodule KilnCMS.Analytics.PoliciesTest do
  @moduledoc """
  RBAC policy coverage for the privacy-first analytics resources (`ContentView`,
  `SearchQuery`).

  Two guarantees: reading aggregates is editor/admin only, and **recording** is
  never available to an external caller — the delivery path writes counts as the
  system (`authorize?: false`). See `docs/policy-matrix.md`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentView
  alias KilnCMS.Analytics.SearchQuery

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      role: role
    })
  end

  setup do
    %{admin: user(:admin), editor: user(:editor), viewer: user(:viewer)}
  end

  # Read policies are filter-applied: an unauthorized actor runs the query and
  # gets zero rows (so `can_*?` is optimistically true for reads). The guarantee
  # under test is therefore "no rows leak", asserted against the real read.
  describe "reading aggregates" do
    setup do
      Analytics.record_view!("page", Ash.UUID.generate(), authorize?: false)
      Analytics.record_search!(%{query: "elixir", result_count: 0}, authorize?: false)
      :ok
    end

    test "view counts are visible to editors/admins, filtered from viewers", %{
      admin: admin,
      editor: editor,
      viewer: viewer
    } do
      assert [_] = Analytics.list_views!(actor: admin)
      assert [_] = Analytics.list_views!(actor: editor)
      assert [] = Analytics.list_views!(actor: viewer)
    end

    test "search aggregates are visible to editors/admins, filtered from viewers", %{
      admin: admin,
      editor: editor,
      viewer: viewer
    } do
      assert [_] = Analytics.top_searches!(actor: editor)
      assert [_] = Analytics.zero_result_searches!(actor: admin)
      assert [] = Analytics.top_searches!(actor: viewer)
      assert [] = Analytics.zero_result_searches!(actor: viewer)
    end
  end

  describe "recording is system-only" do
    test "no non-admin role may record a view", %{editor: editor, viewer: viewer} do
      input = %{content_type: "page", content_id: Ash.UUID.generate()}
      refute Ash.can?({ContentView, :record, input}, editor)
      refute Ash.can?({ContentView, :record, input}, viewer)
      refute Ash.can?({ContentView, :record, input}, nil)
    end

    test "no non-admin role may record a search", %{editor: editor, viewer: viewer} do
      input = %{query: "elixir", result_count: 3}
      refute Ash.can?({SearchQuery, :record, input}, editor)
      refute Ash.can?({SearchQuery, :record, input}, viewer)
      refute Ash.can?({SearchQuery, :record, input}, nil)
    end

    test "the system path writes counts directly (authorize?: false)" do
      assert {:ok, view} =
               Analytics.record_view("page", Ash.UUID.generate(), authorize?: false)

      assert view.views == 1
    end
  end
end
