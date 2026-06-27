defmodule KilnCMS.CMS.AudienceAccessTest do
  @moduledoc """
  Coverage for the consumer-facing audience axis (KilnCMS.CMS.Audiences): the
  content read policy that gates published, audience-restricted records by the
  reader's `audiences`, kept separate from the editorial `role`.

  Assertions are scoped to the records seeded in each test (membership checks,
  not full-table counts) so they stay robust under the shared test sandbox.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  defp user(role, audiences \\ []) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "aud-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role,
      audiences: audiences
    })
  end

  # Seed a page directly in a given state/audience, bypassing the publish
  # workflow (which isn't under test here).
  defp page(audience, state \\ :published) do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: "Aud #{audience}",
      slug: "aud-#{System.unique_integer([:positive])}",
      locale: "en",
      state: state,
      audience: audience
    })
  end

  defp can_read?(page, actor) do
    page.id in Enum.map(CMS.list_pages!(actor: actor), & &1.id)
  end

  describe "default audience" do
    test "content defaults to :public" do
      assert page(:public).audience == :public
      # A seeded page with no explicit audience also lands on :public.
      p =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "D",
          slug: "d-#{System.unique_integer([:positive])}",
          state: :published
        })

      assert p.audience == :public
    end
  end

  describe "published :public content" do
    test "is world-readable (anonymous)" do
      assert can_read?(page(:public), nil)
    end
  end

  describe "published audience-restricted content" do
    test "is hidden from anonymous readers" do
      refute can_read?(page(:member), nil)
    end

    test "is hidden from a signed-in user lacking the audience" do
      refute can_read?(page(:member), user(:viewer, []))
    end

    test "is visible to a user who belongs to the audience" do
      assert can_read?(page(:member), user(:viewer, [:member]))
    end

    test "is visible to editors regardless of audience" do
      assert can_read?(page(:member), user(:editor))
    end

    test "is visible to admins regardless of audience" do
      assert can_read?(page(:member), user(:admin))
    end
  end

  describe "draft content" do
    test "is hidden from anonymous readers even when :public" do
      refute can_read?(page(:public, :draft), nil)
    end

    test "is hidden from a matching-audience viewer (drafts are editors-only)" do
      refute can_read?(page(:member, :draft), user(:viewer, [:member]))
    end
  end

  describe "manage_access action" do
    test "admins can assign role and audiences" do
      admin = user(:admin)
      target = user(:viewer, [])

      updated =
        Accounts.manage_user_access!(target, %{role: :editor, audiences: [:member]}, actor: admin)

      assert updated.role == :editor
      assert updated.audiences == [:member]
    end

    test "non-admins cannot assign access (no self-promotion)" do
      target = user(:viewer, [])

      assert {:error, _} =
               Accounts.manage_user_access(target, %{audiences: [:member]}, actor: target)
    end
  end
end
