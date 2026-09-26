defmodule KilnCMS.Search.Meilisearch.SiteInstanceIsolationTest do
  @moduledoc """
  A site on its own Meilisearch instance and the operator's instance never mix
  (#1558, `KilnCMS.Search.Meilisearch.SiteInstance`'s moduledoc) — driven end
  to end: publish, drain the jobs, and look at every request the Meilisearch
  client was handed.

  The operator's instance is **planted** (`MEILI_*` as app env) with its own
  URL, master key and index, because the test env has Meilisearch off: with
  nothing there, "the operator's key never reaches the site's host" would pass
  whether or not anything kept it out.

    * **isolation** — the site's content goes to the site's URL, with the
      site's key and index, and no request carries the operator's; a site with
      no instance of its own still goes to the operator's.
    * **fail directions** — a site instance that can't be used holds indexing
      (the job fails and retries, no request at all) and turns search into an
      error the caller falls back from (no request at all). Neither ever
      reaches the operator's instance.
    * **SSRF** — a site target's requests go through `KilnCMS.SafeFetch`, which
      refuses a private address before dialling it.

  `async: false` because it rewrites the global Meilisearch config.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.Meilisearch
  alias KilnCMS.Search.MeilisearchWorker

  @operator_url "https://operator-meili.example"
  @operator_key "operator-master-key"
  @site_url "https://search.site.example"

  # Records every request, with the endpoint config it was handed, into the
  # owning test process. Always succeeds.
  defmodule RecordingClient do
    @behaviour KilnCMS.Search.Meilisearch.Client

    @impl true
    def request(method, path, body, config) do
      send(
        Application.get_env(:kiln_cms, :meili_isolation_pid),
        {:meili, method, path, body, config}
      )

      case method do
        :post -> {:ok, %{"hits" => [%{"title" => "Hit"}]}}
        _ -> {:ok, %{"taskUid" => 1}}
      end
    end
  end

  setup do
    original = Application.get_env(:kiln_cms, Meilisearch, [])
    Application.put_env(:kiln_cms, :meili_isolation_pid, self())

    Application.put_env(:kiln_cms, Meilisearch,
      enabled: true,
      url: @operator_url,
      master_key: @operator_key,
      index: "operator_idx",
      client: RecordingClient
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, Meilisearch, original)
      Application.delete_env(:kiln_cms, :meili_isolation_pid)
    end)

    site = KilnCMS.OrgFixtures.org("meili-site")
    plain = KilnCMS.OrgFixtures.org("meili-plain")

    row =
      CMS.save_site_meilisearch!(
        %{url: @site_url, index: "site_idx", api_key: "site-key"},
        tenant: site,
        authorize?: false
      )

    # The save's own reindex (nothing published yet) — not what these tests are about.
    drain()
    flush()

    %{site: site, plain: plain, row: row}
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp flush do
    receive do
      {:meili, _, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp requests do
    receive do
      {:meili, method, path, body, config} -> [{method, path, body, config} | requests()]
    after
      0 -> []
    end
  end

  defp admin(org) do
    user =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "iso-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x",
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: :admin
    })

    user
  end

  defp publish!(org, title) do
    actor = admin(org)

    CMS.create_page!(
      %{title: title, slug: "iso-#{System.unique_integer([:positive])}", blocks: []},
      actor: actor,
      tenant: org
    )
    |> CMS.publish_page!(actor: actor, tenant: org)
  end

  defp break_key!(row) do
    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "site_meilisearch", where: r.id == type(^row.id, :binary_id)),
        set: [api_key_encrypted: :crypto.strong_rand_bytes(48)]
      )
  end

  describe "isolation" do
    test "a site's content goes to its own instance, and nothing of the operator's goes with it",
         %{site: site} do
      page = publish!(site, "Site-only otters")
      drain()

      sent = requests()
      assert [_ | _] = sent

      for {_method, path, _body, config} <- sent do
        assert config.url == @site_url
        assert config.master_key == "site-key"
        assert config.safe == true
        refute path =~ "operator_idx"
      end

      assert Enum.any?(sent, fn {method, path, body, _config} ->
               method == :put and path =~ "/indexes/site_idx/documents" and
                 Enum.any?(body, &(&1.id == "page_#{page.id}"))
             end)
    end

    test "the site's content never reaches the operator's instance", %{site: site} do
      publish!(site, "Never on the operator")
      drain()

      refute Enum.any?(requests(), fn {_method, _path, _body, config} ->
               config.url == @operator_url or config.master_key == @operator_key
             end)
    end

    test "a site with no instance of its own still uses the operator's", %{plain: plain} do
      page = publish!(plain, "Plain otters")
      drain()

      assert Enum.any?(requests(), fn {method, path, body, config} ->
               method == :put and config.url == @operator_url and
                 config.master_key == @operator_key and config.safe == false and
                 path =~ "/indexes/operator_idx/documents" and
                 Enum.any?(body, &(&1.id == "page_#{page.id}"))
             end)
    end

    test "search asks the site's own index, with the site's key", %{site: site} do
      assert {:ok, [%{"title" => "Hit"}]} = Meilisearch.search("otters", org_id: site.id)

      assert [{:post, "/indexes/site_idx/search", body, config}] = requests()
      assert config.url == @site_url
      assert config.master_key == "site-key"
      assert body.filter =~ ~s(org_id = "#{site.id}")
    end

    test "unpublishing deletes from the site's instance, not the operator's", %{site: site} do
      page = publish!(site, "Soon gone")
      drain()
      flush()

      CMS.unpublish_page!(page, actor: admin(site), tenant: site)
      drain()

      deletes = for {:delete, path, _body, config} <- requests(), do: {path, config.url}
      assert {"/indexes/site_idx/documents/page_#{page.id}", @site_url} in deletes
      refute Enum.any?(deletes, fn {_path, url} -> url == @operator_url end)
    end
  end

  describe "fail direction — indexing holds" do
    test "an unusable key holds the job and sends nothing anywhere", %{site: site, row: row} do
      break_key!(row)

      ExUnit.CaptureLog.capture_log(fn ->
        publish!(site, "Held otters")
        drain()
      end)

      assert requests() == []

      assert [%Oban.Job{state: "retryable", errors: [%{"error" => error} | _]}] =
               KilnCMS.Repo.all(
                 from(j in Oban.Job,
                   where:
                     j.worker == "KilnCMS.Search.MeilisearchWorker" and
                       fragment("?->>'op' = 'upsert'", j.args)
                 )
               )

      assert error =~ "held"
      assert %{held: 1} = MeilisearchWorker.pending(site.id)
    end

    test "a reindex, once the key is back, releases what was held", %{site: site, row: row} do
      break_key!(row)

      ExUnit.CaptureLog.capture_log(fn ->
        publish!(site, "Held then freed")
        drain()
      end)

      assert %{held: 1} = MeilisearchWorker.pending(site.id)

      {:ok, [row]} = CMS.list_site_meilisearch(tenant: site, authorize?: false)
      CMS.update_site_meilisearch!(row, %{api_key: "site-key-2"}, tenant: site, authorize?: false)
      # The reindex job runs, succeeds, and moves the held upsert to available.
      drain()
      drain()

      assert %{held: 0, queued: 0} = MeilisearchWorker.pending(site.id)

      sent = requests()
      assert Enum.all?(sent, fn {_m, _p, _b, config} -> config.master_key == "site-key-2" end)
      assert Enum.any?(sent, fn {method, _p, _b, _c} -> method == :put end)
    end
  end

  describe "fail direction — search degrades" do
    test "an unusable key is an error with no request — never the operator's index",
         %{site: site, row: row} do
      break_key!(row)

      assert {:error, {:site_instance, :credentials_unreadable}} =
               Meilisearch.search("otters", org_id: site.id)

      assert requests() == []
    end

    test "settings that can't be read are an error with no request" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:site_instance, :unavailable}} =
                 Meilisearch.search("otters", org_id: "not-an-org-id")
      end)

      assert requests() == []
    end
  end

  describe "SSRF — a site target goes through SafeFetch" do
    test "a private address is refused before anything is dialled" do
      config = %{url: "https://10.0.0.5:7700", master_key: "site-key", safe: true}

      assert {:error, "blocked URL: " <> _reason} =
               Meilisearch.ReqClient.request(:put, "/indexes/x/documents", [%{id: "a"}], config)
    end

    test "so is a metadata address" do
      config = %{url: "https://169.254.169.254", master_key: "site-key", safe: true}

      assert {:error, "blocked URL: " <> _reason} =
               Meilisearch.ReqClient.request(:post, "/indexes/x/search", %{q: "a"}, config)
    end
  end
end
