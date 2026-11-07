defmodule KilnCMSWeb.CustomFieldReadMaskingTest do
  @moduledoc """
  Read restrictions on private custom fields (#2281): an editor whose
  `field_read_grants` hides a private field never receives its value, through
  any surface — JSON:API, GraphQL, MCP, the Ash reads behind the console,
  version history and the restore preview, and the response to their own
  write. A distinctive canary value is stored in the field and every
  serialized response is searched for it; an unrestricted editor must see it,
  so a broken seed cannot make the absence vacuous.

  Read grants apply to private fields only: a non-private field is
  world-readable on published content, so hiding it from one role would be
  theatre. (A private field is always a top-level scalar, so a `:group`'s rows
  are never hidden either.)
  """
  # async: false — `PrivateFields.all/1` is cached per org in a global cache,
  # and these tests define private fields on the shared default org.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @canary "CANARY-7f3a"
  @schema KilnCMSWeb.GraphqlSchema

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "mask-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp key(owner, admin) do
    owner.id
    |> Accounts.mint_api_key!(
      "mask",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: admin
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "mask-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "Field", field_type: :string}, attrs),
      actor: admin
    )
  end

  defp request(method, path, key, body \\ nil) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn = dispatch(conn, @endpoint, method, path, body && Jason.encode!(body))
    {conn.status, conn.resp_body}
  end

  defp mcp(key, name, arguments) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: name, arguments: arguments}
        })
      )

    {conn.status, conn.resp_body}
  end

  defp gql(query, variables, actor) do
    {:ok, result} = Absinthe.run(query, @schema, variables: variables, context: %{actor: actor})
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    inspect(result.data, limit: :infinity, printable_limit: :infinity)
  end

  setup do
    admin = user(:admin)

    field!(admin, %{name: "notes"})
    field!(admin, %{name: "secret", private: true})
    field!(admin, %{name: "other_secret", private: true})

    group = field!(admin, %{name: "dosages", field_type: :group, multiple: true})
    field!(admin, %{name: "dose_note", group_of_id: group.id, content_type: nil})

    fields = %{
      "notes" => "VISIBLE-NOTE",
      "secret" => @canary,
      "other_secret" => "OTHER-" <> @canary,
      "dosages" => [%{"dose_note" => "GROUP-VISIBLE"}]
    }

    published =
      CMS.create_post!(%{title: "Live", slug: slug(), custom_fields: fields}, actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))

    draft = CMS.create_post!(%{title: "Draft", slug: slug(), custom_fields: fields}, actor: admin)

    held =
      CMS.create_post!(%{title: "Held", slug: slug(), custom_fields: fields}, actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))
      |> then(
        &CMS.save_post_working_copy!(
          &1,
          %{
            working_title: "Held draft",
            fields: %{"custom_fields" => %{fields | "secret" => "WC-" <> @canary}}
          },
          actor: admin
        )
      )

    restricted = user(:editor, %{field_read_grants: %{"post" => []}})
    partial = user(:editor, %{field_read_grants: %{"post" => ["custom_fields.other_secret"]}})
    open = user(:editor)

    %{
      admin: admin,
      published: published,
      draft: draft,
      held: held,
      restricted: restricted,
      partial: partial,
      open: open,
      restricted_key: key(restricted, admin),
      open_key: key(open, admin),
      partial_key: key(partial, admin)
    }
  end

  describe "JSON:API" do
    test "a single record, draft or live, leaves the canary out for the restricted editor", ctx do
      for doc <- [ctx.published, ctx.draft, ctx.held] do
        {200, body} = request(:get, "/api/json/posts/#{doc.id}", ctx.restricted_key)
        refute body =~ "7f3a"
        # The rest of the record is untouched.
        assert body =~ "VISIBLE-NOTE"
        assert body =~ "GROUP-VISIBLE"

        {200, open} = request(:get, "/api/json/posts/#{doc.id}", ctx.open_key)
        assert open =~ @canary
      end
    end

    test "the index leaves it out too", ctx do
      {200, body} = request(:get, "/api/json/posts", ctx.restricted_key)
      refute body =~ "7f3a"

      {200, open} = request(:get, "/api/json/posts", ctx.open_key)
      assert open =~ @canary
    end

    test "a partial read grant keeps only the field it names", ctx do
      {200, body} = request(:get, "/api/json/posts/#{ctx.draft.id}", ctx.partial_key)
      assert body =~ "OTHER-" <> @canary
      refute body =~ ~s("secret":"#{@canary}")
      refute body =~ ~s("secret":)
    end

    test "custom_filter and custom_sort cannot probe a hidden field", ctx do
      assert {400, _} =
               request(
                 :get,
                 "/api/json/posts?custom_filter[secret]=#{@canary}",
                 ctx.restricted_key
               )

      assert {400, _} = request(:get, "/api/json/posts?custom_sort=secret", ctx.restricted_key)

      # The visible private field and the unrestricted editor still can.
      assert {200, body} =
               request(:get, "/api/json/posts?custom_filter[secret]=#{@canary}", ctx.open_key)

      assert body =~ @canary

      assert {200, _} =
               request(
                 :get,
                 "/api/json/posts?custom_filter[other_secret]=OTHER-#{@canary}",
                 ctx.partial_key
               )
    end
  end

  describe "filtering and sorting on the whole map" do
    # `custom_fields` is a public attribute, so the API derives
    # `filter[custom_fields]` (equality against the WHOLE map, hidden keys
    # included) and `sort=custom_fields`: both would be an oracle for a hidden
    # key, so a restricted editor is refused them.
    test "JSON:API refuses them to the restricted editor and allows them otherwise", ctx do
      whole = URI.encode_www_form(Jason.encode!(ctx.draft.custom_fields))

      for query <- [
            "filter[custom_fields]=#{whole}",
            "filter[custom_fields][is_nil]=false",
            "sort=custom_fields"
          ] do
        assert {400, body} = request(:get, "/api/json/posts?" <> query, ctx.restricted_key)
        assert body =~ "hidden from you"
        assert {200, _} = request(:get, "/api/json/posts?" <> query, ctx.open_key)
      end
    end

    test "GraphQL refuses a filter on it to the restricted editor", ctx do
      query = """
      query ($filter: PostFilterInput) {
        searchPosts(query: "Draft", filter: $filter) { id }
      }
      """

      whole = Jason.encode!(ctx.draft.custom_fields)

      run = fn actor ->
        Absinthe.run(query, @schema,
          variables: %{"filter" => %{"customFields" => %{"eq" => whole}}},
          context: %{actor: actor}
        )
      end

      assert {:ok, %{errors: [%{message: message} | _]}} = run.(ctx.restricted)
      assert message =~ "hidden from you"
      assert {:ok, %{data: %{"searchPosts" => _}} = result} = run.(ctx.open)
      refute Map.has_key?(result, :errors)
    end
  end

  describe "GraphQL" do
    @by_slug """
    query ($slug: String!) {
      postBySlug(slug: $slug, locale: "en") { title customFields customString(name: "secret") }
    }
    """

    test "a published record leaves the canary out for the restricted editor", ctx do
      refute gql(@by_slug, %{"slug" => ctx.published.slug}, ctx.restricted) =~ "7f3a"
      assert gql(@by_slug, %{"slug" => ctx.published.slug}, ctx.open) =~ @canary
    end
  end

  describe "GraphQL typed readers" do
    # Selecting only the accessors leaves `custom_fields` unloaded on the
    # parent, so the resolver re-reads it as the request's actor.
    test "customString on a hidden field answers nothing", ctx do
      query = """
      query ($slug: String!) {
        postBySlug(slug: $slug, locale: "en") {
          s: customString(name: "secret")
          n: customString(name: "notes")
        }
      }
      """

      hidden = gql(query, %{"slug" => ctx.published.slug}, ctx.restricted)
      refute hidden =~ "7f3a"
      assert hidden =~ "VISIBLE-NOTE"

      assert gql(query, %{"slug" => ctx.published.slug}, ctx.open) =~ @canary
    end
  end

  describe "MCP" do
    test "read_posts leaves the canary out for the restricted editor", ctx do
      {200, body} = mcp(ctx.restricted_key, "read_posts", %{})
      refute body =~ "7f3a"
      assert body =~ "VISIBLE-NOTE"

      {200, open} = mcp(ctx.open_key, "read_posts", %{})
      assert open =~ @canary
    end
  end

  describe "Ash reads (the console)" do
    test "the record and its held working copy are masked", ctx do
      for doc <- [ctx.published, ctx.draft, ctx.held] do
        record = CMS.get_post!(doc.id, actor: ctx.restricted)
        refute inspect(record.custom_fields) =~ "7f3a"
        refute inspect(record.working_fields) =~ "7f3a"
        assert record.custom_fields["notes"] == "VISIBLE-NOTE"

        open = CMS.get_post!(doc.id, actor: ctx.open)
        assert open.custom_fields["secret"] == @canary
      end

      assert inspect(CMS.get_post!(ctx.held.id, actor: ctx.open).working_fields) =~ "WC-"
    end

    test "an admin and an internal read see everything", ctx do
      assert CMS.get_post!(ctx.draft.id, actor: ctx.admin).custom_fields["secret"] == @canary

      assert CMS.get_post!(ctx.draft.id, actor: ctx.restricted, authorize?: false).custom_fields[
               "secret"
             ] == @canary
    end
  end

  describe "history" do
    test "versions are masked, and the restricted editor's diff has the key on neither side",
         ctx do
      versions = CMS.list_post_versions!(actor: ctx.restricted, tenant: ctx.draft.org_id)
      refute inspect(versions) =~ "7f3a"
      assert inspect(versions) =~ "VISIBLE-NOTE"

      open = CMS.list_post_versions!(actor: ctx.open, tenant: ctx.draft.org_id)
      assert inspect(open) =~ @canary
    end

    test "a compare of two versions has the hidden key on neither side", ctx do
      post =
        CMS.update_post!(ctx.draft, %{custom_fields: %{"secret" => "CANARY-NEW"}},
          actor: ctx.admin
        )

      opts = [tenant: post.org_id]

      [older, newer] =
        CMS.list_post_versions!(
          [
            actor: ctx.restricted,
            query: [filter: [version_source_id: post.id], sort: [version_inserted_at: :asc]]
          ] ++ opts
        )
        |> Enum.take(-2)

      {:ok, old, new} =
        KilnCMS.CMS.VersionSnapshot.pair(
          CMS.Post.Version,
          post.id,
          older,
          newer,
          [actor: ctx.restricted] ++ opts
        )

      diff = KilnCMS.CMS.VersionDiff.between(old, new, CMS.Post)
      refute inspect(diff) =~ "CANARY"
      refute inspect(old) =~ "CANARY"
      refute inspect(new) =~ "CANARY"

      {:ok, _old, open_new} =
        KilnCMS.CMS.VersionSnapshot.pair(
          CMS.Post.Version,
          post.id,
          older,
          newer,
          [actor: ctx.open] ++ opts
        )

      assert inspect(open_new) =~ "CANARY-NEW"
    end

    # `CoalesceAutosaveVersions` merges the trailing autosave rows it reads as
    # the saving editor and writes the result back: a masked read there would
    # erase the hidden values from history for good.
    test "coalescing a restricted editor's autosaves keeps the hidden values in history", ctx do
      for title <- ["One", "Two"] do
        ctx.held.id
        |> CMS.get_post!(actor: ctx.restricted)
        |> CMS.save_post_working_copy!(%{working_title: title}, actor: ctx.restricted)
      end

      stored =
        CMS.list_post_versions!(
          actor: ctx.admin,
          tenant: ctx.held.org_id,
          query: [
            filter: [version_source_id: ctx.held.id, version_action_name: :save_working_copy]
          ]
        )

      assert inspect(stored) =~ "WC-" <> @canary
      assert length(stored) == 1
    end

    test "the restore preview carries no hidden value", ctx do
      [version | _] =
        CMS.list_post_versions!(
          actor: ctx.restricted,
          tenant: ctx.draft.org_id,
          query: [filter: [version_source_id: ctx.draft.id]]
        )

      record = CMS.get_post!(ctx.draft.id, actor: ctx.restricted)

      plan =
        KilnCMS.CMS.Changes.RestoreVersion.preview(record, version.id,
          actor: ctx.restricted,
          tenant: record.org_id
        )

      refute inspect(plan.custom_fields) =~ "7f3a"
      refute inspect(plan.values) =~ "7f3a"
    end
  end

  describe "mutation responses" do
    test "a JSON:API PATCH returns no canary, and leaves the stored value byte-identical", ctx do
      stored = CMS.get_post!(ctx.draft.id, actor: ctx.admin).custom_fields

      {200, body} =
        request(:patch, "/api/json/posts/#{ctx.draft.id}", ctx.restricted_key, %{
          data: %{
            type: "post",
            id: ctx.draft.id,
            attributes: %{custom_fields: %{"notes" => "EDITED-BY-RESTRICTED"}}
          }
        })

      refute body =~ "7f3a"
      assert body =~ "EDITED-BY-RESTRICTED"

      after_write = CMS.get_post!(ctx.draft.id, actor: ctx.admin).custom_fields
      assert after_write["notes"] == "EDITED-BY-RESTRICTED"
      assert Map.drop(after_write, ["notes"]) == Map.drop(stored, ["notes"])
      assert after_write["secret"] == @canary
    end

    test "a GraphQL mutation returns no canary and keeps the stored value", ctx do
      mutation = """
      mutation ($id: ID!, $input: UpdatePostInput!) {
        updatePost(id: $id, input: $input) { result { customFields } errors { message } }
      }
      """

      out =
        gql(
          mutation,
          %{
            "id" => ctx.draft.id,
            "input" => %{"customFields" => Jason.encode!(%{"notes" => "VIA-GQL"})}
          },
          ctx.restricted
        )

      refute out =~ "7f3a"
      assert out =~ "VIA-GQL"
      assert CMS.get_post!(ctx.draft.id, actor: ctx.admin).custom_fields["secret"] == @canary
    end

    test "an MCP update returns no canary and keeps the stored value", ctx do
      {200, body} =
        mcp(ctx.restricted_key, "update_post", %{
          id: ctx.draft.id,
          input: %{custom_fields: %{"notes" => "VIA-MCP"}}
        })

      refute body =~ "7f3a"
      assert body =~ "VIA-MCP"
      assert CMS.get_post!(ctx.draft.id, actor: ctx.admin).custom_fields["secret"] == @canary
    end

    test "an internal write (authorize?: false) returns the whole record", ctx do
      updated =
        CMS.update_post!(ctx.draft, %{title: "Internal"},
          actor: ctx.restricted,
          authorize?: false
        )

      assert updated.custom_fields["secret"] == @canary
    end

    test "an Ash update and a working copy save return the masked record", ctx do
      updated =
        CMS.update_post!(ctx.draft, %{title: "Renamed"}, actor: ctx.restricted)

      refute inspect(updated.custom_fields) =~ "7f3a"
      assert CMS.get_post!(ctx.draft.id, actor: ctx.admin).custom_fields["secret"] == @canary

      held =
        CMS.get_post!(ctx.held.id, actor: ctx.restricted)
        |> CMS.save_post_working_copy!(%{working_title: "Again"}, actor: ctx.restricted)

      refute inspect(held.working_fields) =~ "7f3a"

      stored = CMS.get_post!(ctx.held.id, actor: ctx.admin)
      assert stored.working_fields["custom_fields"]["secret"] == "WC-" <> @canary
      assert stored.custom_fields["secret"] == @canary
    end
  end
end
