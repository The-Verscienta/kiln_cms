defmodule KilnCMS.CMS.CommentTest do
  @moduledoc "Block-anchored editorial comment threads (#404)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "comment-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp block_ref do
    {"post", Ecto.UUID.generate(), Ecto.UUID.generate()}
  end

  test "the first comment on a block starts the thread (thread_id nil)" do
    editor = user(:editor)
    {type, content_id, block_id} = block_ref()

    {:ok, root} =
      CMS.add_comment(
        %{content_type: type, content_id: content_id, block_id: block_id, body: "Fix this typo"},
        actor: editor
      )

    assert is_nil(root.thread_id)
    assert root.author_id == editor.id
    assert root.body == "Fix this typo"
  end

  test "a second comment on the same block is routed to the first comment's thread" do
    editor = user(:editor)
    {type, content_id, block_id} = block_ref()

    {:ok, root} =
      CMS.add_comment(
        %{content_type: type, content_id: content_id, block_id: block_id, body: "Fix this typo"},
        actor: editor
      )

    {:ok, reply} =
      CMS.add_comment(
        %{content_type: type, content_id: content_id, block_id: block_id, body: "Done"},
        actor: editor
      )

    assert reply.thread_id == root.id

    assert [listed_root, listed_reply] =
             CMS.list_comments_for_block!(type, content_id, block_id, actor: editor)

    assert listed_root.id == root.id
    assert listed_reply.id == reply.id
  end

  test "a comment on a different block starts its own, separate thread" do
    editor = user(:editor)
    type = "post"
    content_id = Ecto.UUID.generate()
    block_a = Ecto.UUID.generate()
    block_b = Ecto.UUID.generate()

    {:ok, root_a} =
      CMS.add_comment(%{content_type: type, content_id: content_id, block_id: block_a, body: "A"},
        actor: editor
      )

    {:ok, root_b} =
      CMS.add_comment(%{content_type: type, content_id: content_id, block_id: block_b, body: "B"},
        actor: editor
      )

    assert is_nil(root_a.thread_id)
    assert is_nil(root_b.thread_id)
    refute root_a.id == root_b.id
  end

  test "resolving and unresolving the root marks/clears resolved_at and resolved_by" do
    editor = user(:editor)
    admin = user(:admin)
    {type, content_id, block_id} = block_ref()

    {:ok, root} =
      CMS.add_comment(
        %{content_type: type, content_id: content_id, block_id: block_id, body: "Needs a source"},
        actor: editor
      )

    {:ok, resolved} = CMS.resolve_comment(root, %{}, actor: admin)
    assert resolved.resolved_by_id == admin.id
    refute is_nil(resolved.resolved_at)

    {:ok, reopened} = CMS.unresolve_comment(resolved, %{}, actor: admin)
    assert is_nil(reopened.resolved_at)
    assert is_nil(reopened.resolved_by_id)
  end

  test "a reply cannot be resolved directly — only the thread's root" do
    editor = user(:editor)
    {type, content_id, block_id} = block_ref()

    {:ok, root} =
      CMS.add_comment(
        %{content_type: type, content_id: content_id, block_id: block_id, body: "Q"},
        actor: editor
      )

    {:ok, reply} =
      CMS.add_comment(
        %{content_type: type, content_id: content_id, block_id: block_id, body: "A"},
        actor: editor
      )

    assert {:error, %Ash.Error.Invalid{}} = CMS.resolve_comment(reply, %{}, actor: editor)
    assert is_nil(reload(root).resolved_at)
  end

  test "editors may comment and resolve; viewers may not" do
    editor = user(:editor)
    viewer = user(:viewer)
    {type, content_id, block_id} = block_ref()

    assert {:ok, root} =
             CMS.add_comment(
               %{content_type: type, content_id: content_id, block_id: block_id, body: "Hi"},
               actor: editor
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.add_comment(
               %{content_type: type, content_id: content_id, block_id: block_id, body: "Hi"},
               actor: viewer
             )

    assert {:error, %Ash.Error.Forbidden{}} = CMS.resolve_comment(root, %{}, actor: viewer)
  end

  test "list_comments_for returns every comment on a content record, across blocks" do
    editor = user(:editor)
    type = "post"
    content_id = Ecto.UUID.generate()

    CMS.add_comment!(
      %{content_type: type, content_id: content_id, block_id: Ecto.UUID.generate(), body: "A"},
      actor: editor
    )

    CMS.add_comment!(
      %{content_type: type, content_id: content_id, block_id: Ecto.UUID.generate(), body: "B"},
      actor: editor
    )

    assert length(CMS.list_comments_for!(type, content_id, actor: editor)) == 2
  end

  defp reload(comment), do: CMS.get_comment!(comment.id, authorize?: false)
end
