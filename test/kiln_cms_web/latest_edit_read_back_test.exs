defmodule KilnCMSWeb.LatestEditReadBackTest do
  @moduledoc """
  The read-back of the change severity (`KilnCMS.CMS.LatestEdit`): a viewer
  key reads `latest_edit_severity` / `latest_edit_at` from JSON:API, GraphQL
  and `/api/sync`.

  "Latest edit" is the newest version that carries a severity, so a later edit
  of an unlisted field leaves it where it was; a draft, and a document whose
  versions all predate the column, read `nil`.
  """
  # async: false — the safety-field list is cached under the organization
  # alone (see CMS.ChangeSeverityTest), and the sync commit lag is app config.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.LatestEdit
  alias KilnCMS.Test.QueryCounting

  @accept "application/vnd.api+json"
  @schema KilnCMSWeb.GraphqlSchema
  @fields "latest_edit_severity,latest_edit_at"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "latest-edit-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner, admin) do
    owner.id
    |> Accounts.mint_api_key!(
      "latest-edit",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read},
      actor: admin
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "le-#{System.unique_integer([:positive])}"

  defp list_safety(admin, fields) do
    CMS.save_site_safety_fields!(%{fields: fields},
      actor: admin,
      tenant: Accounts.default_org_id()
    )
  end

  defp live_page(admin, attrs \\ %{}) do
    page = CMS.create_page!(Map.merge(%{title: "Live", slug: slug()}, attrs), actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp get_json(path, key) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> get(path)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp json_page(page, key) do
    {200, %{"data" => %{"attributes" => attrs}}} =
      get_json("/api/json/pages/#{page.id}?fields[page]=#{@fields}", key)

    attrs
  end

  # The newest version row carrying a severity, straight from the table.
  defp latest_version(page) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id and &1.change_severity != nil))
    |> Enum.max_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id})
  end

  setup do
    admin = user(:admin)
    %{admin: admin, key: key(user(:viewer), admin)}
  end

  describe "JSON:API" do
    test "a viewer key reads the severity and time of the edit", %{admin: admin, key: key} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)
      CMS.update_page!(page, %{title: "Changed", change_severity: :critical}, actor: admin)

      attrs = json_page(page, key)
      version = latest_version(page)

      assert attrs["latest_edit_severity"] == "critical"
      assert {:ok, at, _} = DateTime.from_iso8601(attrs["latest_edit_at"])
      assert DateTime.compare(at, version.version_inserted_at) == :eq
    end

    test "two consecutive edits read back the later one, not the first",
         %{admin: admin, key: key} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)

      page = CMS.update_page!(page, %{title: "One", change_severity: :routine}, actor: admin)
      first = json_page(page, key)
      assert first["latest_edit_severity"] == "routine"

      CMS.update_page!(page, %{title: "Two", change_severity: :critical}, actor: admin)
      second = json_page(page, key)

      assert second["latest_edit_severity"] == "critical"
      assert second["latest_edit_at"] > first["latest_edit_at"]
    end

    test "a viewer key reads what an API write recorded", %{admin: admin, key: key} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)

      write_key =
        admin.id
        |> Accounts.mint_api_key!(
          "latest-edit-write",
          DateTime.add(DateTime.utc_now(), 1, :day),
          %{access: :read_write},
          actor: admin
        )
        |> Ash.Resource.get_metadata(:plaintext_api_key)

      patch = fn attrs ->
        build_conn()
        |> put_req_header("accept", @accept)
        |> put_req_header("content-type", @accept)
        |> put_req_header("authorization", "Bearer #{write_key}")
        |> patch(
          "/api/json/pages/#{page.id}",
          Jason.encode!(%{data: %{type: "page", attributes: attrs}})
        )
        |> Map.fetch!(:status)
      end

      assert patch.(%{title: "By API", change_severity: "critical"}) == 200
      assert %{"latest_edit_severity" => "critical"} = json_page(page, key)

      # Omitted: recorded :notable, and the later edit replaces the earlier.
      assert patch.(%{title: "By API again"}) == 200
      assert %{"latest_edit_severity" => "notable", "latest_edit_at" => at} = json_page(page, key)
      assert {:ok, at_dt, _} = DateTime.from_iso8601(at)
      assert DateTime.compare(at_dt, latest_version(page).version_inserted_at) == :eq
    end

    # The documented semantics: the last edit of a *safety* field, not the last
    # edit of the document.
    test "a later edit of an unlisted field leaves the safety edit's values",
         %{admin: admin, key: key} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)

      page = CMS.update_page!(page, %{title: "Safety", change_severity: :critical}, actor: admin)
      before = json_page(page, key)

      CMS.update_page!(page, %{seo_title: "Just a tag"}, actor: admin)

      assert json_page(page, key) == before
      assert before["latest_edit_severity"] == "critical"
    end

    test "a document with no severity-bearing version reads nil", %{admin: admin, key: key} do
      # Nothing listed: every version is the legacy shape (severity nil).
      page = live_page(admin)
      CMS.update_page!(page, %{title: "Edited"}, actor: admin)

      assert %{"latest_edit_severity" => nil, "latest_edit_at" => nil} = json_page(page, key)
    end

    test "a draft reads nil even when its history holds a severity", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)
      page = CMS.update_page!(page, %{title: "Safety", change_severity: :critical}, actor: admin)
      CMS.unpublish_page!(page, %{}, actor: admin)

      # A draft is not readable by a viewer; read it as the editor tier would.
      draft = reload(page)
      assert draft.state == :draft

      loaded = Ash.load!(draft, [:latest_edit_severity, :latest_edit_at], authorize?: false)
      assert loaded.latest_edit_severity == nil
      assert loaded.latest_edit_at == nil
    end

    test "the Entry tier of a dynamic type reads back too", %{admin: admin, key: key} do
      definition =
        CMS.create_type_definition!(
          %{name: "le#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      list_safety(admin, %{definition.name => ["title"]})

      entry =
        ContentTypes.create!(definition.name, %{title: "Pancakes", slug: slug()}, actor: admin)

      {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: admin)
      CMS.update_entry!(entry, %{title: "Waffles", change_severity: :notable}, actor: admin)

      assert {200, %{"data" => %{"attributes" => attrs}}} =
               get_json("/api/json/entries/#{entry.id}?fields[entry]=#{@fields}", key)

      assert attrs["latest_edit_severity"] == "notable"
      assert attrs["latest_edit_at"]
    end
  end

  describe "GraphQL" do
    @query """
    query ($slug: String!) {
      pageBySlug(slug: $slug, locale: "en") { latestEditSeverity latestEditAt }
    }
    """

    test "a viewer reads the severity and time", %{admin: admin} do
      viewer = user(:viewer)
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)
      CMS.update_page!(page, %{title: "Changed", change_severity: :critical}, actor: admin)

      assert {:ok, %{data: %{"pageBySlug" => result}} = response} =
               Absinthe.run(@query, @schema,
                 variables: %{"slug" => page.slug},
                 context: %{actor: viewer}
               )

      refute Map.has_key?(response, :errors)
      assert %{"latestEditSeverity" => "critical", "latestEditAt" => at} = result
      assert at
    end
  end

  describe "/api/sync" do
    setup do
      previous = Application.get_env(:kiln_cms, KilnCMS.Firing.Sync)
      Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, commit_lag_seconds: 0)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, previous),
          else: Application.delete_env(:kiln_cms, KilnCMS.Firing.Sync)
      end)

      KilnCMS.Cache.bust_published()
      :ok
    end

    defp sync_items(key) do
      KilnCMS.DataCase.drain_oban()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/sync", %{"initial" => "true", "type" => "page"})

      json_response(conn, 200)["items"]
    end

    test "upsert items carry the latest edit beside the artifact", %{admin: admin, key: key} do
      # Only `blocks` is listed and both pages publish with none, so the first
      # publish of either is not a safety edit.
      list_safety(admin, %{"page" => ["blocks"]})
      edited = live_page(admin)
      untouched = live_page(admin)

      CMS.update_page!(
        edited,
        %{blocks: [%{"_type" => "heading", "text" => "Hi"}], change_severity: :critical},
        actor: admin
      )

      items = Map.new(sync_items(key), &{&1["id"], &1})

      assert %{"latest_edit_severity" => "critical", "latest_edit_at" => at} = items[edited.id]
      assert {:ok, at_dt, _} = DateTime.from_iso8601(at)
      assert DateTime.compare(at_dt, latest_version(edited).version_inserted_at) == :eq

      assert %{"latest_edit_severity" => nil, "latest_edit_at" => nil} = items[untouched.id]
    end
  end

  describe "batching" do
    test "the version lookup costs the same for one page of 2 as of 6", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})

      pages =
        for _ <- 1..6 do
          page = live_page(admin)
          CMS.update_page!(page, %{title: "Changed", change_severity: :routine}, actor: admin)
          reload(page)
        end

      small = count_version_queries(fn -> LatestEdit.for_records(Enum.take(pages, 2)) end)
      large = count_version_queries(fn -> LatestEdit.for_records(pages) end)

      assert small == large
      assert large == 1

      load = fn records ->
        count_version_queries(fn ->
          Ash.load!(records, [:latest_edit_severity, :latest_edit_at], authorize?: false)
        end)
      end

      # Both fields share one lookup, whatever the page size.
      assert load.(Enum.take(pages, 2)) == 1
      assert load.(pages) == 1
    end
  end

  describe "a failed lookup" do
    import ExUnit.CaptureLog

    test "answers no edit and logs, rather than raising", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)
      CMS.update_page!(page, %{title: "Changed", change_severity: :critical}, actor: admin)
      page = reload(page)

      # A tenant the version table cannot be queried with.
      broken = %{page | org_id: "not-a-uuid"}

      log =
        capture_log(fn ->
          assert LatestEdit.for_records([broken, page]) |> Map.keys() == [page.id]
          assert LatestEdit.for_records([broken]) == %{}
        end)

      assert log =~ "latest edit lookup failed"
    end
  end

  # The `pages_versions` reads `fun` makes on this test's behalf.
  defp count_version_queries(fun) do
    {_result, queries} = QueryCounting.queries(fun)
    Enum.count(queries, &(&1.source == "pages_versions"))
  end
end
