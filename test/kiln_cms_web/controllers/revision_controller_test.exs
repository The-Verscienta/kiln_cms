defmodule KilnCMSWeb.RevisionControllerTest do
  @moduledoc """
  `/api/content/:type/:id/revisions` — version history over the headless API.

  An authenticated, editor-tier surface authorized by the version resources' own
  policies with the caller's real actor: anonymous is a 401, anyone the version
  policies deny (viewer, out-of-scope restricted editor, another org, another
  dynamic type) a 404, and restore runs the type's `:restore_version` as the
  caller so a read-only key is refused by the content policies themselves.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.VersionSnapshot

  @password "password123456"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "rev-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp mint(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "revisions-api",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp slug, do: "rev-#{System.unique_integer([:positive])}"

  defp req(method, path, opts \\ []) do
    conn = build_conn() |> put_req_header("accept", "application/json")
    conn = if opts[:org], do: org_conn(conn, opts[:org]), else: conn

    conn =
      case opts[:key] do
        nil -> conn
        key -> put_req_header(conn, "authorization", "Bearer #{key}")
      end

    conn = dispatch(conn, @endpoint, method, path)
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  # A page with three versions: create "One", update "Two", update "Three".
  defp page_with_history(admin, opts \\ []) do
    page = CMS.create_page!(%{title: "One", slug: slug()}, [actor: admin] ++ opts)
    page = CMS.update_page!(page, %{title: "Two"}, [actor: admin] ++ opts)
    CMS.update_page!(page, %{title: "Three", seo_title: "SEO"}, [actor: admin] ++ opts)
  end

  defp versions(page, admin, opts \\ []) do
    CMS.list_page_versions!([actor: admin, query: [filter: [version_source_id: page.id]]] ++ opts)
    |> Enum.sort(&VersionSnapshot.before?/2)
  end

  defp rev_path(type, id), do: "/api/content/#{type}/#{id}/revisions"

  setup do
    admin = user(:admin)
    %{admin: admin, page: page_with_history(admin)}
  end

  describe "who may read history" do
    test "anonymous is a 401, never cached", %{page: page, admin: admin} do
      [first | _] = versions(page, admin)

      for p <- [rev_path(:page, page.id), "#{rev_path(:page, page.id)}/#{first.id}"] do
        assert {401, %{"errors" => [%{"code" => "unauthenticated"}]}, conn} = req(:get, p)
        assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      end

      assert {401, _, _} = req(:post, "#{rev_path(:page, page.id)}/#{first.id}/restore")
    end

    test "an editor's read-only key lists revisions newest first, without values",
         %{page: page} do
      key = mint(user(:editor), :read)

      assert {200, %{"data" => data, "meta" => meta}, conn} =
               req(:get, rev_path(:page, page.id), key: key)

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      assert [third, second, first] = data
      assert Enum.map(data, & &1["action"]) == ["update", "update", "create"]
      assert first["action_type"] == "create"
      assert "title" in first["changed_fields"]
      # Editorial fields only — the derived `search_text` column every save
      # rewrites is not a change anyone came to read.
      refute "search_text" in first["changed_fields"]
      refute "org_id" in first["changed_fields"]
      assert second["changed_fields"] == ["title"]
      assert Enum.sort(third["changed_fields"]) == ["seo_title", "title"]
      assert meta == %{"limit" => 20, "next_cursor" => nil}

      # Field names, never values, on the list.
      for row <- data do
        assert Map.keys(row) |> Enum.sort() ==
                 ~w(action action_type changed_fields id inserted_at user_id)

        refute Map.has_key?(row, "changes")
      end
    end

    test "the acting user is an id, not a user object", %{admin: admin} do
      page = CMS.create_page!(%{title: "Attributed", slug: slug()}, actor: admin)
      key = mint(user(:editor), :read)

      assert {200, %{"data" => [row]}, _} = req(:get, rev_path(:page, page.id), key: key)
      assert row["user_id"] == admin.id
    end

    test "an editor's JWT reads history too", %{page: page} do
      editor = user(:editor)

      assert {200, %{"data" => [_, _, _]}, _} =
               req(:get, rev_path(:page, page.id), key: token(editor))
    end

    test "an admin reads history", %{page: page, admin: admin} do
      assert {200, %{"data" => [_, _, _]}, _} =
               req(:get, rev_path(:page, page.id), key: mint(admin, :read))
    end

    test "a viewer — even with a read-write key — gets a 404 and no changes",
         %{page: page, admin: admin} do
      published = CMS.publish_page!(page, actor: admin)
      [first | _] = versions(published, admin)
      key = mint(user(:viewer), :read_write)

      assert {404, %{"errors" => [%{"code" => "not_found"}]}, conn} =
               req(:get, rev_path(:page, page.id), key: key)

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert {404, body, _} = req(:get, "#{rev_path(:page, page.id)}/#{first.id}", key: key)
      refute Map.has_key?(body, "data")
      assert {404, _, _} = req(:post, "#{rev_path(:page, page.id)}/#{first.id}/restore", key: key)
    end

    test "an editor whose readable_types leave the type out gets a 404 — even on a published page",
         %{page: page, admin: admin} do
      published = CMS.publish_page!(page, actor: admin)
      [first | _] = versions(published, admin)
      key = mint(user(:editor, %{readable_types: ["post"]}), :read)

      # The page itself is readable (it is published) — its history is not.
      assert {404, _, _} = req(:get, rev_path(:page, page.id), key: key)
      assert {404, _, _} = req(:get, "#{rev_path(:page, page.id)}/#{first.id}", key: key)

      # The same editor reads history of a type in scope.
      post = CMS.create_post!(%{title: "In scope", slug: slug()}, actor: admin)
      assert {200, %{"data" => [_]}, _} = req(:get, rev_path(:post, post.id), key: key)
    end
  end

  describe "what a route can reach" do
    test "another org's document and version ids are 404 from this org's host",
         %{admin: admin, page: home} do
      other = KilnCMS.OrgFixtures.org("rev")
      foreign = page_with_history(admin, tenant: other)
      [foreign_version | _] = versions(foreign, admin, tenant: other)
      [home_version | _] = versions(home, admin)
      key = mint(admin, :read_write)

      assert {404, _, _} = req(:get, rev_path(:page, foreign.id), key: key)

      assert {404, _, _} =
               req(:get, "#{rev_path(:page, home.id)}/#{foreign_version.id}", key: key)

      assert {404, _, _} =
               req(:post, "#{rev_path(:page, home.id)}/#{foreign_version.id}/restore", key: key)

      # On its own host the same admin key reads it — and not ours.
      assert {200, %{"data" => [_, _, _]}, _} =
               req(:get, rev_path(:page, foreign.id), key: key, org: other)

      assert {404, _, _} = req(:get, rev_path(:page, home.id), key: key, org: other)

      assert {404, _, _} =
               req(:get, "#{rev_path(:page, foreign.id)}/#{home_version.id}",
                 key: key,
                 org: other
               )
    end

    test "a version of a different document is 404 under this one", %{admin: admin, page: page} do
      other = page_with_history(admin)
      [other_version | _] = versions(other, admin)
      key = mint(admin, :read)

      assert {404, _, _} = req(:get, "#{rev_path(:page, page.id)}/#{other_version.id}", key: key)
    end

    test "a compiled type's route cannot read another type's document", %{admin: admin} do
      post = CMS.create_post!(%{title: "A post", slug: slug()}, actor: admin)
      key = mint(admin, :read)

      assert {404, _, _} = req(:get, rev_path(:page, post.id), key: key)
    end

    test "a dynamic type's route reads its own entries and not another dynamic type's",
         %{admin: admin} do
      first =
        CMS.create_type_definition!(
          %{name: "reva#{System.unique_integer([:positive])}", label: "A"},
          actor: admin
        )

      second =
        CMS.create_type_definition!(
          %{name: "revb#{System.unique_integer([:positive])}", label: "B"},
          actor: admin
        )

      mine = ContentTypes.create!(first.name, %{title: "Mine", slug: slug()}, actor: admin)
      theirs = ContentTypes.create!(second.name, %{title: "Theirs", slug: slug()}, actor: admin)
      key = mint(user(:editor), :read)

      assert {200, %{"data" => [%{"action" => "create"}]}, _} =
               req(:get, rev_path(first.name, mine.id), key: key)

      assert {404, _, _} = req(:get, rev_path(first.name, theirs.id), key: key)

      [their_version] =
        CMS.list_entry_versions!(
          actor: admin,
          query: [filter: [version_source_id: theirs.id]]
        )

      assert {404, _, _} =
               req(:get, "#{rev_path(first.name, theirs.id)}/#{their_version.id}", key: key)

      assert {404, _, _} =
               req(:get, "#{rev_path(first.name, mine.id)}/#{their_version.id}", key: key)
    end

    test "malformed ids are 400s, an unknown type a 404", %{page: page} do
      key = mint(user(:editor), :read)

      assert {400, %{"errors" => [%{"code" => "invalid_id"}]}, _} =
               req(:get, rev_path(:page, "not-a-uuid"), key: key)

      assert {400, _, _} = req(:get, "#{rev_path(:page, page.id)}/not-a-uuid", key: key)
      assert {404, _, _} = req(:get, rev_path(:nosuchtype, page.id), key: key)
      assert {404, _, _} = req(:get, rev_path(:page, Ecto.UUID.generate()), key: key)

      assert {404, _, _} =
               req(:get, "#{rev_path(:page, page.id)}/#{Ecto.UUID.generate()}", key: key)
    end
  end

  describe "pagination" do
    test "a keyset cursor walks the history newest first, once each", %{admin: admin} do
      page = page_with_history(admin)
      page = CMS.update_page!(page, %{title: "Four"}, actor: admin)
      _page = CMS.update_page!(page, %{title: "Five"}, actor: admin)
      key = mint(admin, :read)

      {200, %{"data" => one, "meta" => %{"next_cursor" => c1}}, _} =
        req(:get, rev_path(:page, page.id) <> "?limit=2", key: key)

      {200, %{"data" => two, "meta" => %{"next_cursor" => c2}}, _} =
        req(:get, rev_path(:page, page.id) <> "?limit=2&cursor=#{c1}", key: key)

      {200, %{"data" => three, "meta" => %{"next_cursor" => nil}}, _} =
        req(:get, rev_path(:page, page.id) <> "?limit=2&cursor=#{c2}", key: key)

      walked = Enum.map(one ++ two ++ three, & &1["id"])
      expected = page |> versions(admin) |> Enum.reverse() |> Enum.map(& &1.id)

      assert [_, _] = one
      assert [_, _] = two
      assert [_] = three
      assert walked == expected
    end

    test "a malformed cursor is a 400, a malformed limit the default", %{page: page} do
      key = mint(user(:editor), :read)

      assert {400, %{"errors" => [%{"code" => "invalid_cursor"}]}, _} =
               req(:get, rev_path(:page, page.id) <> "?cursor=garbage", key: key)

      # A bracketed cursor is no cursor (`KilnCMSWeb.Params`): the first page.
      assert {200, %{"data" => [_, _, _]}, _} =
               req(:get, rev_path(:page, page.id) <> "?cursor[]=x", key: key)

      assert {200, %{"meta" => %{"limit" => 20}}, _} =
               req(:get, rev_path(:page, page.id) <> "?limit[]=5", key: key)

      assert {200, %{"meta" => %{"limit" => 20}}, _} =
               req(:get, rev_path(:page, page.id) <> "?limit=100000", key: key)
    end
  end

  describe "one revision" do
    test "carries its own changes and the snapshot VersionSnapshot folds",
         %{admin: admin, page: page} do
      [_first, second, _third] = versions(page, admin)
      key = mint(user(:editor), :read)

      assert {200, %{"data" => data}, conn} =
               req(:get, "#{rev_path(:page, page.id)}/#{second.id}", key: key)

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert data["id"] == second.id
      # The raw version: its own `changes`, bookkeeping included.
      assert %{"title" => "Two"} = data["changes"]
      assert data["changed_fields"] == ["title"]

      {:ok, expected} =
        VersionSnapshot.at(KilnCMS.CMS.Page.Version, page.id, second,
          actor: admin,
          tenant: Accounts.default_org_id()
        )

      assert data["snapshot"] == expected
      assert data["snapshot"]["title"] == "Two"
      assert data["snapshot"]["slug"] == page.slug
      # The fold stops at this version — the later SEO title is not in it.
      assert data["snapshot"]["seo_title"] in [nil, Map.get(expected, "seo_title")]
      refute data["snapshot"]["seo_title"] == "SEO"
    end
  end

  describe "restore" do
    test "a :read_write key on an editor account restores, recorded as a new revision",
         %{admin: admin, page: page} do
      [first | _] = versions(page, admin)
      owner = user(:editor)
      key = mint(owner, :read_write)

      assert {200, %{"data" => data}, conn} =
               req(:post, "#{rev_path(:page, page.id)}/#{first.id}/restore", key: key)

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert data["id"] == page.id
      assert data["type"] == "page"
      assert data["state"] == "draft"
      assert data["restored_version_id"] == first.id
      assert %{"action" => "restore_version", "user_id" => user_id} = data["revision"]
      assert user_id == owner.id

      assert CMS.get_page!(page.id, actor: admin).title == "One"
      assert length(versions(page, admin)) == 4
    end

    test "a read-only key is refused by the content policies — nothing moves",
         %{admin: admin, page: page} do
      [first | _] = versions(page, admin)
      key = mint(user(:editor), :read)

      assert {403, %{"errors" => [%{"code" => "forbidden"}]}, conn} =
               req(:post, "#{rev_path(:page, page.id)}/#{first.id}/restore", key: key)

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert CMS.get_page!(page.id, actor: admin).title == "Three"
      assert length(versions(page, admin)) == 3
    end

    test "anonymous is refused before anything is read", %{admin: admin, page: page} do
      [first | _] = versions(page, admin)

      assert {401, _, _} = req(:post, "#{rev_path(:page, page.id)}/#{first.id}/restore")
      assert CMS.get_page!(page.id, actor: admin).title == "Three"
    end
  end
end
