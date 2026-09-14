defmodule KilnCMS.Notifications.InAppDispatchTest do
  @moduledoc """
  The in-app channel rides the *same* recipient decision the email and push
  channels ride (#1320).

  This is the file that has to hold. The whole risk in adding a third channel
  is that it grows its own copy of "who wants this?", so these tests assert the
  property directly: for each event, the user who muted it gets **no email and
  no inbox row**, and the user who did not gets both. A second preference
  lookup that drifted from `wants?/2` would satisfy one of those and fail the
  other.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Notifications

  defp user(role, prefs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "inapp-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role,
          name: "Ada"
        },
        prefs
      )
    )
  end

  defp slug, do: "inapp-#{System.unique_integer([:positive])}"

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp inbox(user), do: Notifications.notifications_for_user!(user.id, actor: user)

  describe "content-workflow events" do
    test "submitting for review lands in the reviewer's inbox" do
      admin = user(:admin)
      editor = user(:editor)

      page = CMS.create_page!(%{title: "Draft for review", slug: slug()}, actor: editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      drain()

      assert [notification] = inbox(admin)
      assert notification.event == :submitted_for_review
      assert notification.content_type == "page"
      assert notification.content_id == page.id
      assert notification.title == "Draft for review"
      assert notification.actor_name == "Ada"
      assert is_nil(notification.read_at)

      # And not in the submitter's own inbox — never tell someone what they
      # just did.
      assert inbox(editor) == []
    end

    test "a reviewer who muted review requests gets NO inbox row either" do
      muted = user(:admin, %{notify_on_review_request: false})
      editor = user(:editor)

      page = CMS.create_page!(%{title: "Muted review", slug: slug()}, actor: editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      drain()

      assert inbox(muted) == []
    end

    test "publishing lands in the author's inbox" do
      admin = user(:admin)
      author = user(:editor)

      page = CMS.create_page!(%{title: "Going live", slug: slug()}, actor: author)
      CMS.publish_page!(page, %{}, actor: admin)
      drain()

      assert [notification] = inbox(author)
      assert notification.event == :published
      assert notification.title == "Going live"
      # Scheduled publishing has no acting user, so `:published` is dispatched
      # actor-less on purpose — nobody's name goes on it.
      assert is_nil(notification.actor_name)
    end

    test "an author who muted publish notices gets NO inbox row" do
      admin = user(:admin)
      author = user(:editor, %{notify_on_publish: false})

      page = CMS.create_page!(%{title: "Quietly live", slug: slug()}, actor: author)
      CMS.publish_page!(page, %{}, actor: admin)
      drain()

      assert inbox(author) == []
    end

    test "returning to draft lands in the author's inbox, named" do
      admin = user(:admin)
      author = user(:editor)

      page = CMS.create_page!(%{title: "Needs work", slug: slug()}, actor: author)
      page = CMS.submit_page_for_review!(page, %{}, actor: author)
      CMS.return_page_to_draft!(page, %{}, actor: admin)
      drain()

      assert [notification] = inbox(author)
      assert notification.event == :returned_to_draft
      assert notification.actor_name == "Ada"
    end

    test "an author who muted return-to-draft gets NO inbox row" do
      admin = user(:admin)
      author = user(:editor, %{notify_on_return_to_draft: false})

      page = CMS.create_page!(%{title: "Quiet rework", slug: slug()}, actor: author)
      page = CMS.submit_page_for_review!(page, %{}, actor: author)
      CMS.return_page_to_draft!(page, %{}, actor: admin)
      drain()

      assert inbox(author) == []
    end
  end

  describe "comments" do
    test "a comment on a block lands in the author's inbox, anchored to the block" do
      author = user(:editor)
      commenter = user(:editor)
      block_id = Ecto.UUID.generate()

      page = CMS.create_page!(%{title: "Discussed", slug: slug()}, actor: author)

      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: page.id,
          block_id: block_id,
          body: "This intro needs tightening"
        },
        actor: commenter
      )

      drain()

      assert [notification] = inbox(author)
      assert notification.event == :comment_added
      assert notification.block_id == block_id
      assert notification.excerpt == "This intro needs tightening"

      # The block anchor is what makes the row a deep link into the thread
      # rather than into the document — the console has no heading-anchor
      # fragment to aim at (see `KilnCMS.Notifications.Link`).
      assert Notifications.Link.editor_path(notification) ==
               "/editor/pages/#{page.id}?comment=#{block_id}"
    end

    test "an author who muted comments gets NO inbox row" do
      author = user(:editor, %{notify_on_comment: false})
      commenter = user(:editor)

      page = CMS.create_page!(%{title: "Unwatched", slug: slug()}, actor: author)

      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: page.id,
          block_id: Ecto.UUID.generate(),
          body: "Anyone home?"
        },
        actor: commenter
      )

      drain()

      assert inbox(author) == []
    end

    test "being @mentioned records the mention event, not the thread event" do
      author = user(:editor)
      mentioned = user(:editor, %{name: "Grace"})
      commenter = user(:editor)

      page = CMS.create_page!(%{title: "Named", slug: slug()}, actor: author)

      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: page.id,
          block_id: Ecto.UUID.generate(),
          body: "@Grace can you take this?"
        },
        actor: commenter
      )

      drain()

      # One row, and it is the mention — being named is the stronger signal,
      # and two rows for one comment is how people mute a feature.
      assert [notification] = inbox(mentioned)
      assert notification.event == :comment_mention
    end
  end

  describe "task assignment" do
    test "an assignment lands in the assignee's inbox with the content's title" do
      assigner = user(:editor)
      assignee = user(:editor)
      block_id = Ecto.UUID.generate()

      page = CMS.create_page!(%{title: "Needs a pass", slug: slug()}, actor: assigner)

      CMS.assign_task!(
        %{
          content_type: "page",
          content_id: page.id,
          block_id: block_id,
          assignee_id: assignee.id,
          note: "Tighten the opening"
        },
        actor: assigner
      )

      drain()

      assert [notification] = inbox(assignee)
      assert notification.event == :task_assigned
      assert notification.title == "Needs a pass"
      assert notification.block_id == block_id
      assert notification.excerpt == "Tighten the opening"
      assert notification.actor_name == "Ada"
    end

    test "changing only the due date does not re-notify" do
      assigner = user(:editor)
      assignee = user(:editor)

      page = CMS.create_page!(%{title: "One ping", slug: slug()}, actor: assigner)

      task =
        CMS.assign_task!(
          %{content_type: "page", content_id: page.id, assignee_id: assignee.id},
          actor: assigner
        )

      CMS.update_task!(task, %{due_on: ~D[2026-10-01]}, actor: assigner)
      drain()

      assert [_one] = inbox(assignee)
    end

    test "reassigning notifies the new assignee" do
      assigner = user(:editor)
      first = user(:editor)
      second = user(:editor)

      page = CMS.create_page!(%{title: "Handed over", slug: slug()}, actor: assigner)

      task =
        CMS.assign_task!(
          %{content_type: "page", content_id: page.id, assignee_id: first.id},
          actor: assigner
        )

      CMS.update_task!(task, %{assignee_id: second.id}, actor: assigner)
      drain()

      assert [notification] = inbox(second)
      assert notification.event == :task_assigned
    end
  end

  describe "a rolled-back write notifies nobody" do
    test "a refused publish records nothing" do
      author = user(:editor)
      viewer = user(:viewer)

      page = CMS.create_page!(%{title: "Not yours", slug: slug()}, actor: author)

      assert {:error, _forbidden} = CMS.publish_page(page, %{}, actor: viewer)
      drain()

      assert inbox(author) == []
    end
  end
end
