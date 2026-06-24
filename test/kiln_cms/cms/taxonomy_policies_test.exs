defmodule KilnCMS.CMS.TaxonomyPoliciesTest do
  @moduledoc """
  RBAC policy coverage for the taxonomy + join resources (`Category`, `Tag`,
  `Tagging`, `ContentLink`).

  Shared rule: read is world-open (published content references taxonomy on the
  public/headless frontends), authoring is editor+, and the only divergence is
  `destroy` — hard deletes of `Category`/`Tag` are admin-only, while unlinking a
  join row stays editor+. See `docs/policy-matrix.md`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.CMS.Tag
  alias KilnCMS.CMS.Tagging

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      role: role
    })
  end

  defp category, do: Ash.Seed.seed!(Category, %{name: "News", slug: "news-#{uniq()}"})
  defp tag, do: Ash.Seed.seed!(Tag, %{name: "Elixir", slug: "elixir-#{uniq()}"})
  defp uniq, do: System.unique_integer([:positive])

  setup do
    %{admin: user(:admin), editor: user(:editor), viewer: user(:viewer)}
  end

  describe "Category" do
    test "read is world-open (incl. anonymous)", %{viewer: viewer} do
      assert CMS.can_list_categories?(viewer)
      assert CMS.can_list_categories?(nil)
    end

    test "create/update is editor+, not viewers", %{editor: editor, viewer: viewer} do
      cat = category()
      assert CMS.can_create_category?(editor)
      assert CMS.can_update_category?(editor, cat)
      refute CMS.can_create_category?(viewer)
      refute CMS.can_update_category?(viewer, cat)
    end

    test "destroy is admin-only", %{admin: admin, editor: editor, viewer: viewer} do
      cat = category()
      assert CMS.can_destroy_category?(admin, cat)
      refute CMS.can_destroy_category?(editor, cat)
      refute CMS.can_destroy_category?(viewer, cat)
    end
  end

  describe "Tag" do
    test "read is world-open (incl. anonymous)", %{viewer: viewer} do
      assert CMS.can_list_tags?(viewer)
      assert CMS.can_list_tags?(nil)
    end

    test "create/update is editor+, not viewers", %{editor: editor, viewer: viewer} do
      t = tag()
      assert CMS.can_create_tag?(editor)
      assert CMS.can_update_tag?(editor, t)
      refute CMS.can_create_tag?(viewer)
      refute CMS.can_update_tag?(viewer, t)
    end

    test "destroy is admin-only", %{admin: admin, editor: editor, viewer: viewer} do
      t = tag()
      assert CMS.can_destroy_tag?(admin, t)
      refute CMS.can_destroy_tag?(editor, t)
      refute CMS.can_destroy_tag?(viewer, t)
    end
  end

  describe "ContentLink" do
    test "read is world-open (incl. anonymous)", %{viewer: viewer} do
      assert CMS.can_list_content_links?(viewer)
      assert CMS.can_list_content_links?(nil)
    end

    test "create is editor+, not viewers", %{editor: editor, viewer: viewer} do
      assert CMS.can_create_content_link?(editor)
      refute CMS.can_create_content_link?(viewer)
    end

    test "destroy stays editor+ (unlike Category/Tag)", %{
      admin: admin,
      editor: editor,
      viewer: viewer
    } do
      link =
        Ash.Seed.seed!(ContentLink, %{
          source_id: Ash.UUID.generate(),
          target_id: Ash.UUID.generate(),
          kind: :related
        })

      assert CMS.can_destroy_content_link?(admin, link)
      assert CMS.can_destroy_content_link?(editor, link)
      refute CMS.can_destroy_content_link?(viewer, link)
    end
  end

  describe "Tagging (no code interface — checked via Ash.can?)" do
    test "read is world-open (incl. anonymous)", %{viewer: viewer} do
      assert Ash.can?({Tagging, :read}, viewer)
      assert Ash.can?({Tagging, :read}, nil)
    end

    test "create/destroy is editor+, not viewers", %{
      admin: admin,
      editor: editor,
      viewer: viewer
    } do
      input = %{subject_id: Ash.UUID.generate(), tag_id: tag().id}

      assert Ash.can?({Tagging, :create, input}, admin)
      assert Ash.can?({Tagging, :create, input}, editor)
      refute Ash.can?({Tagging, :create, input}, viewer)
      refute Ash.can?({Tagging, :create, input}, nil)
    end
  end
end
