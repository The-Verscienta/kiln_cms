defmodule KilnCMS.CMS.FieldGrantsTest do
  @moduledoc "Per-field write grants for editors (granular RBAC #332, slice 3)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "grants-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "grants-#{System.unique_integer([:positive])}"

  defp post!(actor), do: CMS.create_post!(%{title: "Post", slug: slug()}, actor: actor)

  describe "enforcement on update" do
    test "a granted editor may change granted fields and nothing else" do
      admin = user(:admin)
      post = post!(admin)
      editor = user(:editor, %{field_grants: %{"post" => ["title"]}})

      assert {:ok, updated} = CMS.update_post(post, %{title: "Renamed"}, actor: editor)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_post(updated, %{excerpt: "New excerpt"}, actor: editor)

      assert Exception.message(error) =~ "field grant"
    end

    test "resubmitting unchanged values is not a violation (form-style saves)" do
      admin = user(:admin)
      post = post!(admin)
      editor = user(:editor, %{field_grants: %{"post" => ["title"]}})

      # The editor form posts every field; unchanged values must pass.
      assert {:ok, _} =
               CMS.update_post(post, %{title: "Renamed", slug: post.slug, locale: post.locale},
                 actor: editor
               )
    end

    test "the block_tree argument requires the blocks grant" do
      admin = user(:admin)
      post = post!(admin)

      title_only = user(:editor, %{field_grants: %{"post" => ["title"]}})

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_post(
                 post,
                 %{block_tree: [%{"type" => "markdown", "text" => "hi"}]},
                 actor: title_only
               )

      blocks_granted = user(:editor, %{field_grants: %{"post" => ["title", "blocks"]}})

      assert {:ok, _} =
               CMS.update_post(
                 post,
                 %{block_tree: [%{"type" => "markdown", "text" => "hi"}]},
                 actor: blocks_granted
               )
    end

    test "workflow transitions are unaffected by a narrow grant" do
      editor = user(:editor, %{field_grants: %{"post" => ["title"]}})
      post = CMS.create_post!(%{title: "Mine", slug: slug()}, actor: editor)

      # submit_for_review changes :state internally — no user-supplied content
      # attributes, so the grant does not block the verb.
      assert {:ok, _} = CMS.submit_post_for_review(post, actor: editor)
    end

    test "types without a grant entry, admins, and creates are unrestricted" do
      admin = user(:admin, %{field_grants: %{"post" => ["title"]}})
      editor = user(:editor, %{field_grants: %{"page" => ["title"]}})

      # No "post" entry in the editor's grants → posts unrestricted.
      post = post!(admin)
      assert {:ok, post} = CMS.update_post(post, %{excerpt: "Free"}, actor: editor)

      # Admin grants are ignored.
      assert {:ok, _} = CMS.update_post(post, %{excerpt: "Also free"}, actor: admin)

      # Creating a new post is gated by editable_types, not field grants.
      assert {:ok, _} = CMS.create_post(%{title: "New", slug: slug()}, actor: editor)
    end
  end

  describe "membership resolution" do
    test "a membership grant wins over the user column for that org" do
      org =
        Ash.Seed.seed!(Organization, %{
          name: "Grants #{System.unique_integer([:positive])}",
          slug: "grants-#{System.unique_integer([:positive])}"
        })

      admin = user(:admin)
      post = CMS.create_post!(%{title: "Org post", slug: slug()}, actor: admin, tenant: org)

      editor = user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: editor.id,
        organization_id: org.id,
        role: :editor,
        field_grants: %{"post" => ["title"]}
      })

      assert {:ok, _} = CMS.update_post(post, %{title: "Renamed"}, actor: editor, tenant: org)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_post(post, %{excerpt: "Nope"}, actor: editor, tenant: org)

      # The same editor on the default org has no grants → unrestricted.
      default_post = post!(admin)
      assert {:ok, _} = CMS.update_post(default_post, %{excerpt: "Free"}, actor: editor)
    end
  end
end
