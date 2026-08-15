defmodule KilnCMS.CMS.CommentBroadcastTest do
  @moduledoc """
  `KilnCMS.CMS.Changes.BroadcastComment` fans a thread change out to two
  audiences: the pop-out preview's pins and the editors' own per-block counts.
  They are separate topics with separate subscribers, so each needs its own
  assertion — a regression that drops one is invisible from the other.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Collab
  alias KilnCMSWeb.PreviewLive

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bcast-comment-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp subscribe_both(content_id) do
    :ok = Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic(:page, content_id))
    :ok = Phoenix.PubSub.subscribe(KilnCMS.PubSub, Collab.topic(:page, content_id))
  end

  defp add(content_id, block_id, actor, body \\ "Look at this") do
    CMS.add_comment(
      %{content_type: "page", content_id: content_id, block_id: block_id, body: body},
      actor: actor
    )
  end

  test "adding a comment reaches the preview AND the editors" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()
    subscribe_both(content_id)

    {:ok, _comment} = add(content_id, block_id, editor)

    assert_receive {:preview_comments_changed, ^block_id}
    assert_receive {:block_thread_changed, ^block_id}
    drain()
  end

  test "a reply announces its block too — the count moved even though the thread didn't" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()

    {:ok, _root} = add(content_id, block_id, editor)
    subscribe_both(content_id)

    {:ok, reply} = add(content_id, block_id, editor, "Agreed")

    refute is_nil(reply.thread_id)
    assert_receive {:block_thread_changed, ^block_id}
    drain()
  end

  test "resolving and reopening both announce on both topics" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()

    {:ok, root} = add(content_id, block_id, editor)
    subscribe_both(content_id)

    {:ok, resolved} = CMS.resolve_comment(root, %{}, actor: editor)
    assert_receive {:preview_comments_changed, ^block_id}
    assert_receive {:block_thread_changed, ^block_id}

    {:ok, _reopened} = CMS.unresolve_comment(resolved, %{}, actor: editor)
    assert_receive {:preview_comments_changed, ^block_id}
    assert_receive {:block_thread_changed, ^block_id}
    drain()
  end

  test "a rejected write announces on neither topic" do
    viewer = user(:viewer)
    content_id = Ecto.UUID.generate()
    subscribe_both(content_id)

    assert {:error, _} = add(content_id, Ecto.UUID.generate(), viewer)

    refute_receive {:preview_comments_changed, _}
    refute_receive {:block_thread_changed, _}
    drain()
  end

  test "the announcement is scoped to its own document" do
    editor = user(:editor)
    subscribe_both(Ecto.UUID.generate())

    {:ok, _comment} = add(Ecto.UUID.generate(), Ecto.UUID.generate(), editor)

    refute_receive {:preview_comments_changed, _}
    refute_receive {:block_thread_changed, _}
    drain()
  end
end
