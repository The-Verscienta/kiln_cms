defmodule KilnCMSWeb.GraphqlSubscriptionTest do
  @moduledoc """
  GraphQL subscriptions end to end (real-time headless): a client on the
  `/ws/gql` socket subscribes to `<type>Changed` and receives pushes as
  content changes — resolved per subscriber through the policy-scoped read,
  so anonymous subscribers only ever receive published-visible data, while a
  bearer-authed editor also sees draft activity. The shared entry tier gives
  every admin-defined dynamic type the same feed.
  """
  # async: false — subscriptions register on the global endpoint registry.
  # The Batcher is off in test (config), so resolution happens synchronously
  # in the publishing (test) process and stays on the sandbox connection.
  use KilnCMS.DataCase, async: false

  import Phoenix.ChannelTest

  use Absinthe.Phoenix.SubscriptionTest, schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.GraphqlSocket

  @endpoint KilnCMSWeb.Endpoint
  @password "password123456"
  # Post-guard-lift, subscriptions are tenant-scoped (#336): a subscriber resolves
  # its org from the connecting host (the default org for a host-less test socket),
  # so the content whose changes it should receive must be written under that same
  # org — exactly as an editor's tenant-threaded writes do in production.
  @org KilnCMS.Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "sub-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp bearer_token(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp subscribe!(doc, params \\ %{}) do
    {:ok, socket} = connect(GraphqlSocket, params)
    {:ok, socket} = join_absinthe(socket)

    ref = push_doc(socket, doc)
    assert_reply(ref, :ok, %{subscriptionId: subscription_id})
    {socket, subscription_id}
  end

  defp slug, do: "sub-#{System.unique_integer([:positive])}"

  @page_changed """
  subscription {
    pageChanged {
      created { id title }
      updated { id title }
      destroyed
    }
  }
  """

  test "anonymous subscribers receive published changes but never drafts" do
    {_socket, subscription_id} = subscribe!(@page_changed)
    actor = admin()

    # Draft create + edit: invisible to an anonymous subscriber.
    page = CMS.create_page!(%{title: "Quiet draft", slug: slug()}, actor: actor, tenant: @org)
    page = CMS.update_page!(page, %{title: "Still quiet"}, actor: actor, tenant: @org)
    refute_push("subscription:data", _any, 100)

    # Publishing makes it visible — the update lands as `updated`.
    page = CMS.publish_page!(page, %{}, actor: actor, tenant: @org)

    assert_push("subscription:data", %{result: result, subscriptionId: ^subscription_id})

    assert %{data: %{"pageChanged" => %{"updated" => %{"id" => id, "title" => title}}}} = result
    assert id == page.id
    assert title == "Still quiet"

    # Publishing runs internal follow-up updates (published-version pointer,
    # artifact bookkeeping) that also notify — drain those pushes.
    drain_pushes()

    # Published edits keep flowing.
    CMS.update_page!(page, %{title: "Live v2"}, actor: actor, tenant: @org)

    assert_push("subscription:data", %{result: %{data: %{"pageChanged" => changed}}})
    assert %{"updated" => %{"title" => "Live v2"}} = changed
  end

  defp drain_pushes do
    receive do
      %Phoenix.Socket.Message{event: "subscription:data"} -> drain_pushes()
    after
      150 -> :ok
    end
  end

  test "a bearer-authed editor sees draft activity too" do
    actor = admin()
    {_socket, subscription_id} = subscribe!(@page_changed, %{"token" => bearer_token(actor)})

    page = CMS.create_page!(%{title: "Editor draft", slug: slug()}, actor: actor, tenant: @org)

    assert_push("subscription:data", %{result: result, subscriptionId: ^subscription_id})
    assert %{data: %{"pageChanged" => %{"created" => %{"id" => id}}}} = result
    assert id == page.id
  end

  test "the entry tier feeds every dynamic type through entryChanged" do
    actor = admin()

    definition =
      CMS.create_type_definition!(
        %{name: "sub#{System.unique_integer([:positive])}", label: "Sub"},
        actor: actor,
        tenant: @org
      )

    # Create before subscribing, so the only push is the publish transition.
    entry =
      KilnCMS.CMS.ContentTypes.create!(
        definition.name,
        %{title: "Dyn live", slug: slug()},
        actor: actor,
        tenant: @org
      )

    {_socket, _subscription_id} =
      subscribe!(
        """
        subscription {
          entryChanged {
            updated { id title }
          }
        }
        """,
        %{"token" => bearer_token(actor)}
      )

    {:ok, entry} =
      KilnCMS.CMS.ContentTypes.transition(definition.name, "publish", entry,
        actor: actor,
        tenant: @org
      )

    assert_push("subscription:data", %{result: %{data: %{"entryChanged" => changed}}})
    assert %{"updated" => %{"id" => id}} = changed
    assert id == entry.id
  end
end
