defmodule KilnCMS.Analytics.ContentViewTest do
  @moduledoc """
  Recording a view upserts a per-content counter (atomic increment); reading the
  analytics is editor/admin only.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "an-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  test "recording the same content repeatedly increments one counter row" do
    id = Ash.UUID.generate()

    Analytics.record_view!("page", id, authorize?: false)
    Analytics.record_view!("page", id, authorize?: false)
    Analytics.record_view!("page", id, authorize?: false)

    rows = Analytics.list_views!(authorize?: false)

    assert [%{content_type: "page", content_id: ^id, views: 3, last_viewed_at: %DateTime{}}] =
             rows
  end

  test "different content items get separate counters, sorted most-viewed first" do
    a = Ash.UUID.generate()
    b = Ash.UUID.generate()

    Analytics.record_view!("page", a, authorize?: false)
    Analytics.record_view!("post", b, authorize?: false)
    Analytics.record_view!("post", b, authorize?: false)

    assert [%{content_id: ^b, views: 2}, %{content_id: ^a, views: 1}] =
             Analytics.list_views!(authorize?: false)
  end

  test "analytics is visible to editors/admins but not viewers" do
    Analytics.record_view!("page", Ash.UUID.generate(), authorize?: false)

    assert [_] = Analytics.list_views!(actor: user(:editor))
    assert [_] = Analytics.list_views!(actor: user(:admin))

    # The read policy filters non-editors to nothing (defence-in-depth on top of
    # the editor-only route).
    assert [] = Analytics.list_views!(actor: user(:viewer))
  end
end
