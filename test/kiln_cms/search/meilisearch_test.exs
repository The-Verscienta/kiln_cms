defmodule KilnCMS.Search.MeilisearchTest do
  @moduledoc """
  The optional Meilisearch backend (Project Plan Phase 6): publishing enqueues an
  upsert into the index and unpublishing enqueues a delete, both off the write
  path via `KilnCMS.Search.MeilisearchWorker`. Disabled by default, so the lean
  install enqueues nothing. Uses a stub HTTP client that records calls into the
  test process — no Meilisearch server required.
  """
  # async: false — toggles the global `KilnCMS.Search.Meilisearch` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.Meilisearch

  # Records every request into the owning test process so assertions can inspect
  # what was sent. Always succeeds.
  defmodule StubClient do
    @behaviour KilnCMS.Search.Meilisearch.Client

    @impl true
    def request(method, path, body, _config) do
      pid = Application.get_env(:kiln_cms, :meili_test_pid)
      send(pid, {:meili, method, path, body})
      {:ok, %{"taskUid" => 1}}
    end
  end

  defp put_meili_env(overrides) do
    base = Application.get_env(:kiln_cms, Meilisearch, [])
    Application.put_env(:kiln_cms, Meilisearch, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, Meilisearch, [])
    Application.put_env(:kiln_cms, :meili_test_pid, self())

    on_exit(fn ->
      Application.put_env(:kiln_cms, Meilisearch, original)
      Application.delete_env(:kiln_cms, :meili_test_pid)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "meili-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "meili-#{System.unique_integer([:positive])}"

  defp drain, do: Oban.drain_queue(queue: :default, with_recursion: true)

  describe "config flag" do
    test "disabled by default" do
      refute Meilisearch.enabled?()
    end
  end

  describe "to_document/1" do
    test "builds a flat, prefixed document with a unix published_at" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Otters", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      doc = Meilisearch.to_document(page)

      assert doc.id == "page_#{page.id}"
      assert doc.type == "page"
      assert doc.title == "Otters"
      assert doc.slug == page.slug
      assert is_integer(doc.published_at)
    end
  end

  describe "indexing on publish/unpublish (disabled)" do
    test "publishing enqueues no Meilisearch job when disabled" do
      actor = admin()

      CMS.create_page!(%{title: "Quiet", slug: slug(), blocks: []}, actor: actor)
      |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      refute_received {:meili, _method, _path, _body}
    end
  end

  describe "indexing on publish/unpublish (enabled)" do
    setup do
      put_meili_env(enabled: true, client: StubClient, index: "test_idx")
      :ok
    end

    test "publishing upserts the document into the index" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Indexed", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      assert %{success: success} = drain()
      assert success > 0

      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [doc]}
      assert doc.id == "page_#{page.id}"
      assert doc.title == "Indexed"
    end

    test "unpublishing deletes the document from the index" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Temp", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      CMS.unpublish_page!(page, actor: actor)
      drain()

      assert_received {:meili, :delete, "/indexes/test_idx/documents/page_" <> rest, nil}
      assert rest == page.id
    end
  end

  describe "search/2" do
    test "returns {:error, :disabled} when the backend is off" do
      assert {:error, :disabled} = Meilisearch.search("anything")
    end

    test "posts the query and returns hits when enabled" do
      put_meili_env(enabled: true, client: __MODULE__.SearchStub, index: "test_idx")
      assert {:ok, [%{"title" => "Hit"}]} = Meilisearch.search("hit", type: :page, locale: "en")
      assert_received {:search_body, body}
      assert body.q == "hit"
      assert body.filter == ~s(type = page AND locale = "en")
    end
  end

  # Separate stub returning a hits payload for the search assertion.
  defmodule SearchStub do
    @behaviour KilnCMS.Search.Meilisearch.Client

    @impl true
    def request(:post, _path, body, _config) do
      send(Application.get_env(:kiln_cms, :meili_test_pid), {:search_body, body})
      {:ok, %{"hits" => [%{"title" => "Hit"}]}}
    end
  end
end
