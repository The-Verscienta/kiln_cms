defmodule KilnCMS.Notifications.NotificationTest do
  @moduledoc """
  The persisted in-app notification (#1320): its authorization, its tenancy,
  and the read/unread lifecycle the bell and `/editor/inbox` drive.

  The policy tests here are the ones that matter. A notification list is a
  reading history — who was named in which review note, which drafts someone
  is watching — so "only its own recipient may read it" is the whole security
  model of the feature, and it has to be pinned against a *same-org colleague*
  rather than only against an outsider: an org-scoped resource whose policy
  accidentally reduces to "is in this tenant" passes every cross-tenant test
  and still hands one editor another's inbox.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link
  alias KilnCMS.Notifications.Notification

  doctest KilnCMS.Notifications.Link

  defp user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "inbox-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # `org_id` is `writable? false` — it comes from the tenant, never from
  # input — so it is lifted out of the attrs and passed as `tenant:`.
  defp record(user, attrs \\ %{}) do
    {org_id, attrs} = Map.pop(attrs, :org_id)

    {:ok, notification} =
      Notifications.record_notification(
        Map.merge(
          %{
            user_id: user.id,
            event: :comment_mention,
            content_type: "page",
            content_id: Ecto.UUID.generate(),
            title: "A draft"
          },
          attrs
        ),
        tenant: org_id
      )

    notification
  end

  describe "reading is self-only" do
    test "the recipient reads their own notifications" do
      me = user()
      mine = record(me)

      assert [read] = Notifications.notifications_for_user!(me.id, actor: me)
      assert read.id == mine.id
    end

    test "a colleague in the SAME org cannot read them" do
      me = user()
      colleague = user()
      record(me)

      # The colleague asking for their own list is the honest call, and it is
      # empty: the notification is not theirs.
      assert Notifications.notifications_for_user!(colleague.id, actor: colleague) == []

      # And asking for MINE by id — the action argument is just a filter, so
      # nothing stops them passing my id. The policy has to be what refuses,
      # not the argument. Break `authorize_if expr(user_id == ^actor(:id))` to
      # `authorize_if always()` and this assertion is the one that goes red.
      assert Notifications.notifications_for_user!(me.id, actor: colleague) == []
    end

    test "a colleague cannot read one by id either" do
      me = user()
      colleague = user()
      mine = record(me)

      # Row-filtered rather than forbidden: the read policy is a filter, so
      # the row simply is not there for them. Ash wraps the `NotFound` in an
      # `Invalid` class error.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Notifications.get_notification(mine.id, actor: colleague)

      assert {:ok, %Notification{}} = Notifications.get_notification(mine.id, actor: me)
    end

    test "a platform admin is not exempt — there is deliberately no admin bypass" do
      me = user()

      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "inbox-admin-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      record(me)

      assert Notifications.notifications_for_user!(me.id, actor: admin) == []
    end

    test "an actor-less read returns nothing rather than everything" do
      me = user()
      record(me)

      # `^actor(:id)` templates to nil, so the filter is `user_id == NULL`,
      # which no row satisfies. Fail-closed, not fail-open.
      assert Notifications.notifications_for_user!(me.id) == []
    end
  end

  describe "writing is the notifier's, not a request's" do
    test "an actor-carrying call to :notify is forbidden" do
      me = user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Notifications.record_notification(
                 %{
                   user_id: me.id,
                   event: :published,
                   content_type: "page",
                   content_id: Ecto.UUID.generate(),
                   title: "Mine now"
                 },
                 actor: me
               )
    end

    test "an unknown event is refused" do
      me = user()

      assert {:error, %Ash.Error.Invalid{}} =
               Notifications.record_notification(%{
                 user_id: me.id,
                 event: :invented,
                 content_type: "page",
                 content_id: Ecto.UUID.generate(),
                 title: "Nope"
               })
    end
  end

  describe "tenancy" do
    test "a notification recorded under one org is not in another org's list" do
      me = user()
      other_org = KilnCMS.OrgFixtures.org("notif-other")

      mine = record(me, %{org_id: other_org.id})

      # Read scoped to the org it was written under: found.
      assert [found] =
               Notifications.notifications_for_user!(me.id, actor: me, tenant: other_org.id)

      assert found.id == mine.id

      # Scoped to a different org: absent.
      assert Notifications.notifications_for_user!(me.id,
               actor: me,
               tenant: KilnCMS.Accounts.default_org_id()
             ) == []
    end

    # Through `record_in_app/1` — the production write path — rather than the
    # raw code interface, because the thing at risk is that *function's*
    # `tenant:`. Written against the raw interface, this test passes with the
    # tenant dropped from `record_in_app/1` entirely: the row lands on the
    # default org and the fail-open build finds it by id anyway.
    test "record_in_app/1 stamps the org it was handed, not the default one" do
      me = user()
      other_org = KilnCMS.OrgFixtures.org("notif-stamp")

      assert :ok =
               Notifications.record_in_app(%{
                 user_id: me.id,
                 org_id: other_org.id,
                 event: :published,
                 content_type: "page",
                 content_id: Ecto.UUID.generate(),
                 title: "Stamped"
               })

      assert [stamped] =
               Notifications.notifications_for_user!(me.id, actor: me, tenant: other_org.id)

      assert stamped.org_id == other_org.id

      assert Notifications.notifications_for_user!(me.id,
               actor: me,
               tenant: KilnCMS.Accounts.default_org_id()
             ) == []
    end
  end

  describe "read state" do
    test "a fresh notification is unread and counts" do
      me = user()
      record(me)

      assert [unread] = Notifications.unread_notifications_for_user!(me.id, actor: me)
      assert is_nil(unread.read_at)
    end

    test "marking read drops it out of the unread list" do
      me = user()
      mine = record(me)

      {:ok, marked} = Notifications.mark_notification_read(mine, actor: me)

      assert marked.read_at
      assert Notifications.unread_notifications_for_user!(me.id, actor: me) == []
      assert [_still_listed] = Notifications.notifications_for_user!(me.id, actor: me)
    end

    test "re-marking read keeps the first timestamp" do
      me = user()
      mine = record(me)

      {:ok, first} = Notifications.mark_notification_read(mine, actor: me)
      {:ok, again} = Notifications.mark_notification_read(first, actor: me)

      assert again.read_at == first.read_at
    end

    test "marking unread puts it back in the count" do
      me = user()
      mine = record(me)

      {:ok, marked} = Notifications.mark_notification_read(mine, actor: me)
      {:ok, restored} = Notifications.mark_notification_unread(marked, actor: me)

      assert is_nil(restored.read_at)
      assert [_one] = Notifications.unread_notifications_for_user!(me.id, actor: me)
    end

    test "a colleague cannot mark someone else's notification read" do
      me = user()
      colleague = user()
      mine = record(me)

      assert {:error, error} = Notifications.mark_notification_read(mine, actor: colleague)
      assert %Ash.Error.Forbidden{} = error
    end
  end

  describe "deep links" do
    test "a block-anchored notification links to the thread, not just the document" do
      me = user()
      block_id = Ecto.UUID.generate()
      mine = record(me, %{content_type: "post", block_id: block_id})

      assert Link.editor_path(mine) == "/editor/posts/#{mine.content_id}?comment=#{block_id}"
    end

    test "a document-level notification links to the document" do
      me = user()
      mine = record(me, %{content_type: "page", event: :published})

      assert Link.editor_path(mine) == "/editor/pages/#{mine.content_id}"
    end

    test "a dynamic entry type goes through the generic content route" do
      me = user()
      mine = record(me, %{content_type: "recipe"})

      assert Link.editor_path(mine) == "/editor/content/recipe/#{mine.content_id}"
    end

    test "the email's absolute URL is the same link" do
      assert Link.editor_url("post", "abc", "b1") ==
               KilnCMSWeb.Endpoint.url() <> Link.editor_path("post", "abc", "b1")
    end
  end

  describe "broadcast" do
    test "record_in_app announces on the recipient's topic and nobody else's" do
      me = user()
      someone_else = user()

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Notifications.topic(me.id))
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Notifications.topic(someone_else.id))

      assert :ok =
               Notifications.record_in_app(%{
                 user_id: me.id,
                 org_id: nil,
                 event: :published,
                 content_type: "page",
                 content_id: Ecto.UUID.generate(),
                 title: "Announced"
               })

      assert_receive :notifications_changed
      # Only one: the topic is per-user, so the other subscription stays quiet.
      refute_receive :notifications_changed, 50
    end

    test "a failed write announces nothing" do
      me = user()
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Notifications.topic(me.id))

      # An invalid event: the create raises inside `record_in_app/1`, which
      # logs and returns `:ok` — but must not announce a row that is not there.
      assert :ok =
               Notifications.record_in_app(%{
                 user_id: me.id,
                 org_id: nil,
                 event: :invented,
                 content_type: "page",
                 content_id: Ecto.UUID.generate(),
                 title: "Never stored"
               })

      refute_receive :notifications_changed, 50
      assert Notifications.notifications_for_user!(me.id, actor: me) == []
    end
  end
end
