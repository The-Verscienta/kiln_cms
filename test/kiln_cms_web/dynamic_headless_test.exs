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

    # #300: the entries tier has the universal /published feed too.
    test "the /published feed lists published entries only" do
      actor = admin()
      definition = define_type!(actor)

      published = publish!(definition, entry!(definition, %{title: "Fed"}, actor), actor)
      _draft = entry!(definition, %{title: "Fed draft"}, actor)

      {200, %{"data" => data}} =
        api_get("/api/json/entries/published?filter[type_name]=#{definition.name}")

      assert Enum.map(data, & &1["id"]) == [published.id]
    end
  end

  # #626: the entry tier mirrors the compiled types' write surface, and
  # `return_to_draft` was missing from both. `test/kiln_cms_web/write_api_test.exs`
  # covers the compiled-type side; this is the generic-tier twin, which has its
  # own `routes do` block and so its own way to be forgotten.
  describe "JSON:API /api/json/entries — return-to-draft (#626)" do
    # Bearer API key, the same surface `write_api_test.exs` drives the compiled
    # types through — this is the headless path the issue is about, not a session.
    defp mint(owner, access) do
      key =
        KilnCMS.Accounts.mint_api_key!(
          owner.id,
          "dyn-write-api",
          DateTime.add(DateTime.utc_now(), 30, :day),
          %{access: access},
          actor: admin()
        )

      Ash.Resource.get_metadata(key, :plaintext_api_key)
    end

    defp api_patch(path, id, owner) do
      body = %{data: %{type: "entry", id: id, attributes: %{}}}

      conn =
        build_conn()
        |> put_req_header("accept", @accept)
        |> put_req_header("content-type", @accept)
        |> put_req_header("authorization", "Bearer #{mint(owner, :read_write)}")
        |> dispatch(@endpoint, :patch, path, Jason.encode!(body))

      {conn.status, conn.resp_body}
    end

    test "an admin can send an in-review entry back to its author" do
      actor = admin()
      definition = define_type!(actor)
      entry = entry!(definition, %{title: "Draft entry"}, actor)

      {:ok, in_review} =
        ContentTypes.transition(definition.name, "submit", entry, actor: actor)

      assert in_review.state == :in_review

      assert {200, _} =
               api_patch("/api/json/entries/#{entry.id}/return-to-draft", entry.id, actor)

      assert ContentTypes.get_record!(definition.name, entry.id, actor: actor).state == :draft
    end

    test "an editor is refused — the OrgAdmin gate survives the new route" do
      actor = admin()
      definition = define_type!(actor)
      entry = entry!(definition, %{title: "Draft entry"}, actor)

      {:ok, _in_review} =
        ContentTypes.transition(definition.name, "submit", entry, actor: actor)

      editor =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "dynhl-ed-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      assert {403, _} =
               api_patch("/api/json/entries/#{entry.id}/return-to-draft", entry.id, editor)

      assert ContentTypes.get_record!(definition.name, entry.id, actor: actor).state == :in_review
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
