defmodule KilnCMSWeb.DynamicHeadlessTest do
  @moduledoc """
  Phase 4 (decision D17): the generic headless surface for dynamic types — the
  `/api/json/entries` JSON:API collection (filterable by `type_name`), the
  curated GraphQL entry queries, and webhook events named after the dynamic
  type. Anonymous requests go through the read policy: published entries only.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Webhooks

  @accept "application/vnd.api+json"
  @schema KilnCMSWeb.GraphqlSchema

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dynhl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define_type!(actor) do
    CMS.create_type_definition!(
      %{name: "hl#{System.unique_integer([:positive])}", label: "Headless"},
      actor: actor
    )
  end

  defp entry!(definition, attrs, actor) do
    ContentTypes.create!(
      definition.name,
      Map.put_new(attrs, :slug, "hl-#{System.unique_integer([:positive])}"),
      actor: actor
    )
  end

  defp publish!(definition, entry, actor) do
    {:ok, published} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)
    published
  end

  defp api_get(path) do
    conn = build_conn() |> put_req_header("accept", @accept) |> get(path)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp run(query, variables \\ %{}), do: Absinthe.run(query, @schema, variables: variables)

  describe "JSON:API /api/json/entries" do
    test "anonymous callers see published entries only, filterable by type_name" do
      actor = admin()
      first = define_type!(actor)
      second = define_type!(actor)

      published = publish!(first, entry!(first, %{title: "Visible"}, actor), actor)
      other = publish!(second, entry!(second, %{title: "Other type"}, actor), actor)
      draft = entry!(first, %{title: "Hidden draft"}, actor)

      {200, %{"data" => data}} = api_get("/api/json/entries?filter[type_name]=#{first.name}")
      ids = Enum.map(data, & &1["id"])

      assert published.id in ids
      refute other.id in ids
      refute draft.id in ids

      assert %{"attributes" => %{"title" => "Visible"}} =
               Enum.find(data, &(&1["id"] == published.id))
    end

    test "the search route matches published entries by keyword" do
      actor = admin()
      definition = define_type!(actor)
      token = "zanzibar#{System.unique_integer([:positive])}"

      published =
        publish!(definition, entry!(definition, %{title: "About #{token}"}, actor), actor)

      _draft = entry!(definition, %{title: "Draft #{token}"}, actor)

      {200, %{"data" => data}} = api_get("/api/json/entries/search?query=#{token}&locale=en")

      assert Enum.map(data, & &1["id"]) == [published.id]
    end
  end

  describe "GraphQL entry queries" do
    test "entryBySlug resolves a published entry with its typeName" do
      actor = admin()
      definition = define_type!(actor)
      published = publish!(definition, entry!(definition, %{title: "Via GQL"}, actor), actor)

      query = """
      query {
        entryBySlug(slug: "#{published.slug}", locale: "en",
                    typeDefinitionId: "#{definition.id}") {
          id title typeName published
        }
      }
      """

      assert {:ok, %{data: %{"entryBySlug" => found}}} = run(query)
      assert found["id"] == published.id
      assert found["typeName"] == definition.name
      assert found["published"] == true
    end

    test "searchEntries filters by typeName and hides drafts" do
      actor = admin()
      first = define_type!(actor)
      second = define_type!(actor)
      token = "quokka#{System.unique_integer([:positive])}"

      hit = publish!(first, entry!(first, %{title: "One #{token}"}, actor), actor)
      _other = publish!(second, entry!(second, %{title: "Two #{token}"}, actor), actor)
      _draft = entry!(first, %{title: "Three #{token}"}, actor)

      query = """
      query {
        searchEntries(query: "#{token}",
                      filter: {typeName: {eq: "#{first.name}"}}) {
          id
        }
      }
      """

      assert {:ok, %{data: %{"searchEntries" => results}}} = run(query)
      assert Enum.map(results, & &1["id"]) == [hit.id]
    end
  end

  describe "webhooks for dynamic types" do
    test "events are named after the dynamic type, and endpoints can subscribe" do
      actor = admin()
      definition = define_type!(actor)

      assert "#{definition.name}.published" in WebhookEndpoint.events()

      test_pid = self()

      Req.Test.stub(KilnCMS.Webhooks, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:delivered, Map.new(conn.req_headers), body})
        Req.Test.json(conn, %{ok: true})
      end)

      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: actor)
      entry = entry!(definition, %{title: "Hooked"}, actor)
      publish!(definition, entry, actor)
      KilnCMS.DataCase.drain_oban()

      assert_received {:delivered, headers, body}
      assert headers["x-kilncms-event"] == "#{definition.name}.published"
      assert headers["x-kilncms-signature"] == Webhooks.signature(endpoint.secret, body)
      assert %{"data" => %{"title" => "Hooked"}} = Jason.decode!(body)
    end
  end
end
