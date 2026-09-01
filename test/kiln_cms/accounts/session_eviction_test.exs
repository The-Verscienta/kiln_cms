defmodule KilnCMS.Accounts.SessionEvictionTest do
  @moduledoc """
  A live socket is dropped when its holder's authorization changes (#675).

  Every socket authorizes **once** — at connect, and at join for channels — and
  never again. `CollabChannel.handle_in("update", …)` re-checks nothing; it only
  needs the `doc_server` its join resolved. So an account that was demoted,
  removed from an org, or erased kept everything its live sockets already had,
  for as long as the tab stayed open, while every HTTP surface refused it
  immediately.

  Two halves, and both can fail silently:

    * the **sockets** have to be droppable at all — `GraphqlSocket.id/1`
      returned `nil` (Phoenix for "never"), `BridgeSocket` is a raw transport
      with no `id/1` callback, and nothing set a `live_socket_id` for `/live`;
    * the **actions** that narrow a grant have to fire the eviction.

  A test that only checked the second would pass against sockets that ignore it.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.User

  defp user!(role \\ :editor) do
    Ash.Seed.seed!(User, %{
      email: "evict-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp admin!, do: user!(:admin)

  # Stands in for a connected socket: subscribes to the topic the sockets
  # subscribe to, so the assertion is "the broadcast the sockets act on was
  # sent", not "a function was called".
  defp watch(user_id) do
    KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(user_id))
  end

  # The two directions need different shapes (#1350). The broadcast crosses
  # PubSub, and 200ms used to be the whole budget for the POSITIVE claim — a
  # slow delivery read as "not evicted" and failed the test. Presence is now
  # awaited generously; absence keeps its short observation window, which can
  # only false-pass, never flake.
  defp assert_evicted(user_id) do
    topic = SessionEviction.topic(user_id)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 2_000
  end

  defp refute_evicted(user_id) do
    topic = SessionEviction.topic(user_id)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 200
  end

  describe "the actions that narrow a grant" do
    test "demoting a user evicts them" do
      user = user!(:editor)
      watch(user.id)

      {:ok, _demoted} = Accounts.manage_user_access(user, %{role: :viewer}, actor: admin!())

      assert_evicted(user.id)
    end

    test "narrowing editable_types evicts them" do
      # The issue's second acceptance criterion: an in-flight collab room must
      # stop accepting updates once the editor loses the type.
      user = user!(:editor)
      watch(user.id)

      {:ok, _narrowed} =
        Accounts.manage_user_access(user, %{editable_types: ["page"]}, actor: admin!())

      assert_evicted(user.id)
    end

    test "erasing a user evicts them" do
      user = user!(:editor)
      watch(user.id)

      {:ok, _anonymized} = Accounts.anonymize_user(user, actor: admin!())

      assert_evicted(user.id)
    end

    test "an ordinary preference change does not" do
      # Eviction costs a reconnect, so it fires on the actions that change a
      # grant rather than on every write to the row.
      user = user!(:editor)
      watch(user.id)

      {:ok, _updated} =
        Accounts.update_notification_prefs(user, %{notify_on_publish: false}, actor: user)

      refute_evicted(user.id)
    end
  end

  describe "the sockets can actually be dropped" do
    test "the collab socket's id is the eviction topic" do
      user = user!()
      socket = %Phoenix.Socket{assigns: %{actor: user}}

      assert KilnCMSWeb.CollabSocket.id(socket) == SessionEviction.topic(user.id)
    end

    test "an anonymous graphql socket has no id, since it holds no grant" do
      assert KilnCMSWeb.GraphqlSocket.id(%Phoenix.Socket{assigns: %{}}) == nil
    end

    test "the bridge socket subscribes itself and stops on a real broadcast" do
      # Driven through `init/1` and `Endpoint.broadcast/3` rather than by
      # hand-building the message: constructing a `%Phoenix.Socket.Broadcast{}`
      # and calling `handle_info/2` proves the clause matches, not that the
      # socket ever *receives* one — and deleting the subscription in `init/1`
      # left that version of this test green.
      user = user!()

      # `org: nil` is a placeholder: `init/1` also schedules the periodic
      # re-check (#775), which is 30s away and so never fires inside this test.
      # `KilnCMSWeb.BridgeSocketTest` is where that half is exercised.
      state = %{type: "page", id: Ecto.UUID.generate(), actor: user, org: nil}

      assert {:ok, ^state} = KilnCMSWeb.BridgeSocket.init(state)

      SessionEviction.evict(user.id, :test)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"} = message, 500

      assert {:stop, :normal, ^state} = KilnCMSWeb.BridgeSocket.handle_info(message, state)
    end

    test "an anonymous bridge socket subscribes to nothing" do
      state = %{type: "page", id: Ecto.UUID.generate(), actor: nil, org: nil}

      assert {:ok, ^state} = KilnCMSWeb.BridgeSocket.init(state)

      SessionEviction.evict(Ecto.UUID.generate(), :test)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 200
    end

    test "an unrelated message does not stop the bridge socket" do
      state = %{type: "page", id: Ecto.UUID.generate(), actor: nil, org: nil}

      assert {:ok, ^state} = KilnCMSWeb.BridgeSocket.handle_info(:something_else, state)
    end
  end

  describe "grants that reach a user indirectly" do
    test "narrowing a role evicts everyone holding it" do
      # A role carries the scopes on behalf of every member pointing at it, so
      # evicting "the record's user" reaches nobody — one edit to one role
      # silently missed every member.
      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org",
          slug: "org-#{System.unique_integer([:positive])}"
        })

      role =
        Ash.Seed.seed!(KilnCMS.Accounts.Role, %{
          name: "Blog editor",
          org_id: org.id,
          editable_types: ["post", "page"]
        })

      member = user!(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: member.id,
        organization_id: org.id,
        role_id: role.id
      })

      watch(member.id)

      {:ok, _narrowed} =
        Accounts.update_role(role, %{editable_types: ["page"]}, authorize?: false)

      assert_evicted(member.id)
    end

    test "revoking an API key evicts its owner" do
      # The key is the *entire* credential of the bridge socket, which
      # authorizes once and then streams drafts — revoking a leaked key did not
      # stop the leak until the tab closed.
      owner = user!(:editor)

      {:ok, key} =
        Accounts.mint_api_key(owner.id, "ci", DateTime.add(DateTime.utc_now(), 30, :day),
          authorize?: false
        )

      watch(owner.id)

      {:ok, _revoked} = Accounts.revoke_api_key(key, authorize?: false)

      assert_evicted(owner.id)
    end

    test "removing an org membership evicts its holder" do
      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org",
          slug: "org-#{System.unique_integer([:positive])}"
        })

      member = user!(:editor)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: member.id,
          organization_id: org.id
        })

      watch(member.id)

      :ok = Accounts.remove_org_membership(membership, authorize?: false)

      # Keyed on `user_id`, not the membership's own `id` — evicting that would
      # broadcast on a topic no socket listens on.
      assert_evicted(member.id)
    end
  end

  describe "the broadcaster and the listeners agree" do
    test "one function builds the topic for all four sockets" do
      # The failure mode this guards is silent: two spellings leave the sockets
      # connected while the caller believes they were dropped.
      user_id = Ecto.UUID.generate()
      topic = SessionEviction.topic(user_id)

      assert topic == "user_sockets:#{user_id}"

      assert KilnCMSWeb.CollabSocket.id(%Phoenix.Socket{assigns: %{actor: %{id: user_id}}}) ==
               topic

      assert KilnCMSWeb.GraphqlSocket.id(%Phoenix.Socket{assigns: %{kiln_actor_id: user_id}}) ==
               topic
    end
  end

  describe "eviction cannot break the action that triggered it" do
    @tag :capture_log
    test "a nil user id is logged rather than swallowed or raised" do
      # It must not crash the action that narrowed the grant — but it must not
      # be silent either. A change wired with the wrong `user_id:` field arrives
      # here as nil, every action succeeds, and no socket ever drops.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = SessionEviction.evict(nil, :whatever)
        end)

      assert log =~ "no user id to evict"
    end
  end
end
