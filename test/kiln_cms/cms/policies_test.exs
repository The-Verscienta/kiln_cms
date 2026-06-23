defmodule KilnCMS.CMS.PoliciesTest do
  @moduledoc """
  RBAC policy coverage for the CMS resources (Page/Post/MediaItem).

  Verifies the core security guarantees: unauthenticated/viewer reads are
  limited to published content, editors can author but not hard-delete, and
  admins bypass everything.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.CMS.WebhookEndpoint

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      role: role
    })
  end

  defp page(attrs) do
    # Seed directly so fixtures don't depend on the very policies under test.
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "T", slug: "s-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(%{title: "T", slug: "p-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp media_item(attrs \\ %{}) do
    Ash.Seed.seed!(
      MediaItem,
      Map.merge(
        %{
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 1024,
          storage_key: "photo-#{System.unique_integer([:positive])}.jpg",
          url: "/uploads/photo.jpg"
        },
        attrs
      )
    )
  end

  defp webhook(attrs \\ %{}) do
    Ash.Seed.seed!(
      WebhookEndpoint,
      Map.merge(
        %{
          url: "https://example.com/hooks/#{System.unique_integer([:positive])}",
          events: WebhookEndpoint.events(),
          active: true,
          secret: WebhookEndpoint.generate_secret()
        },
        attrs
      )
    )
  end

  setup do
    admin = user(:admin)
    editor = user(:editor)
    viewer = user(:viewer)

    published = page(%{state: :published})
    draft = page(%{state: :draft})

    %{
      admin: admin,
      editor: editor,
      viewer: viewer,
      published: published,
      draft: draft
    }
  end

  describe "read visibility by role" do
    test "anonymous (no actor) sees only published", %{published: published} do
      ids = CMS.list_pages!(authorize?: true) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "viewer sees only published", %{viewer: viewer, published: published} do
      ids = CMS.list_pages!(actor: viewer) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "editor sees published and unpublished", %{
      editor: editor,
      published: published,
      draft: draft
    } do
      ids = CMS.list_pages!(actor: editor) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end

    test "admin sees everything", %{admin: admin, published: published, draft: draft} do
      ids = CMS.list_pages!(actor: admin) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end
  end

  describe "write authorization by role" do
    # Uses the `can_*?/2` authorization helpers Ash generates from the domain
    # code interfaces.
    test "editors may create, viewers may not", %{editor: editor, viewer: viewer} do
      assert CMS.can_create_page?(editor)
      refute CMS.can_create_page?(viewer)
    end

    test "editors may update, viewers may not", %{editor: editor, viewer: viewer, draft: draft} do
      assert CMS.can_update_page?(editor, draft)
      refute CMS.can_update_page?(viewer, draft)
    end

    test "only admins may destroy", %{admin: admin, editor: editor, draft: draft} do
      assert CMS.can_destroy_page?(admin, draft)
      refute CMS.can_destroy_page?(editor, draft)
    end

    test "only admins may publish", %{admin: admin, editor: editor, draft: draft} do
      assert CMS.can_publish_page?(admin, draft)
      refute CMS.can_publish_page?(editor, draft)
    end

    test "editors may submit for review", %{editor: editor, draft: draft} do
      assert CMS.can_submit_page_for_review?(editor, draft)
    end
  end

  describe "Post read visibility by role" do
    setup %{editor: editor} do
      published = post(%{state: :published})
      draft = post(%{state: :draft})
      %{published_post: published, draft_post: draft, editor: editor}
    end

    test "anonymous sees only published posts", %{published_post: published} do
      ids = CMS.list_posts!(authorize?: true) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "editor sees published and draft posts", %{
      editor: editor,
      published_post: published,
      draft_post: draft
    } do
      ids = CMS.list_posts!(actor: editor) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end
  end

  describe "Post write authorization by role" do
    setup %{editor: editor, viewer: viewer} do
      draft = post(%{state: :draft})
      %{draft_post: draft, editor: editor, viewer: viewer}
    end

    test "editors may create and update posts", %{editor: editor, draft_post: draft} do
      assert CMS.can_create_post?(editor)
      assert CMS.can_update_post?(editor, draft)
    end

    test "viewers may not create or update posts", %{viewer: viewer, draft_post: draft} do
      refute CMS.can_create_post?(viewer)
      refute CMS.can_update_post?(viewer, draft)
    end
  end

  describe "MediaItem policies" do
    setup %{admin: admin, editor: editor, viewer: viewer} do
      item = media_item()
      %{media: item, admin: admin, editor: editor, viewer: viewer}
    end

    test "media is world-readable", %{media: media} do
      assert {:ok, _} = CMS.get_media_item(media.id, authorize?: true)
    end

    test "editors may upload media", %{editor: editor} do
      assert CMS.can_create_media_item?(editor)
    end

    test "viewers may not upload media", %{viewer: viewer} do
      refute CMS.can_create_media_item?(viewer)
    end

    test "only admins may destroy media", %{admin: admin, editor: editor, media: media} do
      assert CMS.can_destroy_media_item?(admin, media)
      refute CMS.can_destroy_media_item?(editor, media)
    end
  end

  describe "WebhookEndpoint policies" do
    setup %{admin: admin, editor: editor} do
      endpoint = webhook()
      %{endpoint: endpoint, admin: admin, editor: editor}
    end

    test "only admins can read webhook endpoints", %{
      admin: admin,
      editor: editor,
      endpoint: endpoint
    } do
      assert {:ok, _} = CMS.get_webhook_endpoint(endpoint.id, actor: admin)
      assert {:error, %Ash.Error.Invalid{}} = CMS.get_webhook_endpoint(endpoint.id, actor: editor)
    end

    test "only admins can manage webhook endpoints", %{admin: admin, editor: editor} do
      assert CMS.can_create_webhook_endpoint?(admin)
      refute CMS.can_create_webhook_endpoint?(editor)
    end
  end
end
