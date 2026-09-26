defmodule KilnCMS.Search.Meilisearch.SiteInstanceTest do
  @moduledoc """
  A site's own Meilisearch instance (#1558): the row
  (`KilnCMS.CMS.SiteMeilisearch`) and the resolver both indexing and search ask
  (`KilnCMS.Search.Meilisearch.SiteInstance`).

    * **authorization** — only an admin of the site reads or writes it; one
      site's admin can't see another's.
    * **precedence** — a row switched on wins; none, or switched off, is the
      operator's instance (or nothing); one site's row never reaches another.
    * **fail direction** — a row that can't be used is an error, never the
      operator's instance.
    * **the tenant boundary** — a private, plain-HTTP or credential-carrying
      URL is refused at save.
    * **the key** — encrypted, kept on a blank save, required when on.
    * **reindex on change** — every write enqueues one.

  `KilnCMS.Search.Meilisearch.SiteInstanceIsolationTest` drives the whole
  pipeline with the operator's instance planted.
  """
  # async: false — some tests switch the operator's instance on in app env.
  use KilnCMS.DataCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Search.Meilisearch
  alias KilnCMS.Search.Meilisearch.SiteInstance
  alias KilnCMS.Search.MeilisearchWorker

  setup do
    original = Application.get_env(:kiln_cms, Meilisearch, [])
    on_exit(fn -> Application.put_env(:kiln_cms, Meilisearch, original) end)

    %{org: KilnCMS.OrgFixtures.org("meili"), other: KilnCMS.OrgFixtures.org("meili-other")}
  end

  defp operator_on! do
    base = Application.get_env(:kiln_cms, Meilisearch, [])

    Application.put_env(
      :kiln_cms,
      Meilisearch,
      Keyword.merge(base,
        enabled: true,
        url: "https://operator-meili.example",
        master_key: "operator-master-key",
        index: "operator_idx"
      )
    )
  end

  defp instance!(org, attrs \\ %{}) do
    %{url: "https://search.site.example", index: "site_idx", api_key: "site-key"}
    |> Map.merge(attrs)
    |> CMS.save_site_meilisearch!(tenant: org, authorize?: false)
  end

  defp force_column!(row, column, value) do
    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "site_meilisearch", where: r.id == type(^row.id, :binary_id)),
        set: [{column, value}]
      )
  end

  defp user(org, tier) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "meili-#{tier}-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x",
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })

    user
  end

  @attrs %{url: "https://search.site.example", index: "site_idx", api_key: "site-key"}

  describe "authorization" do
    test "a site admin can write and read their own site's row", %{org: org} do
      admin = user(org, :admin)

      assert {:ok, _row} = CMS.save_site_meilisearch(@attrs, actor: admin, tenant: org)
      assert {:ok, [_row]} = CMS.list_site_meilisearch(actor: admin, tenant: org)
    end

    test "an editor of the site can neither write nor read it", %{org: org} do
      instance!(org)
      editor = user(org, :editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_meilisearch(@attrs, actor: editor, tenant: org)

      refute CMS.can_save_site_meilisearch?(editor, tenant: org)
      # A read policy filters rather than refuses: the row is simply not there.
      assert {:ok, []} = CMS.list_site_meilisearch(actor: editor, tenant: org)
    end

    test "anonymous can't read it", %{org: org} do
      instance!(org)
      assert {:ok, []} = CMS.list_site_meilisearch(actor: nil, tenant: org)
    end

    test "one site's admin sees nothing of another site's row", %{org: org, other: other} do
      instance!(org)
      admin_of_other = user(other, :admin)

      # On their own site the row simply isn't there...
      assert {:ok, []} = CMS.list_site_meilisearch(actor: admin_of_other, tenant: other)

      # ...and on this site they have no tier at all.
      refute CMS.can_save_site_meilisearch?(admin_of_other, tenant: org)
    end
  end

  describe "precedence" do
    test "no row and no operator instance is no Meilisearch", %{org: org} do
      assert :disabled = SiteInstance.resolve(org.id)
      refute SiteInstance.active?(org.id)
    end

    test "no row is the operator's instance, when it has one", %{org: org} do
      operator_on!()

      assert {:ok, %{source: :operator, url: "https://operator-meili.example", safe: false}} =
               SiteInstance.resolve(org.id)

      assert SiteInstance.active?(org.id)
    end

    test "a row switched on is the site's instance, and nothing of the operator's",
         %{org: org} do
      operator_on!()
      instance!(org)

      assert {:ok, target} = SiteInstance.resolve(org.id)

      assert target == %{
               source: :site,
               url: "https://search.site.example",
               master_key: "site-key",
               index: "site_idx",
               safe: true
             }
    end

    test "a row switched on turns indexing on even with no operator instance", %{org: org} do
      instance!(org)
      assert SiteInstance.active?(org.id)
      assert Meilisearch.enabled_for?(org.id)
    end

    test "a row switched off is the operator's instance", %{org: org} do
      operator_on!()
      instance!(org, %{enabled: false})

      assert {:ok, %{source: :operator}} = SiteInstance.resolve(org.id)
    end

    test "one site's row never reaches another site", %{org: org, other: other} do
      instance!(org)
      assert :disabled = SiteInstance.resolve(other.id)
      refute SiteInstance.active?(other.id)
    end
  end

  describe "fail direction — never the operator's instance" do
    test "an undecryptable key is an error, not the operator's instance", %{org: org} do
      operator_on!()
      row = instance!(org)
      # What a SECRET_KEY_BASE rotation leaves behind.
      force_column!(row, :api_key_encrypted, :crypto.strong_rand_bytes(48))

      assert {:error, :credentials_unreadable} = SiteInstance.resolve(org.id)
      # The gate still says yes, so the job exists to hold.
      assert SiteInstance.active?(org.id)
    end

    test "a row that can't be read is an error, and the gate still enqueues" do
      operator_on!()

      ExUnit.CaptureLog.capture_log(fn ->
        # Not a uuid: the tenant filter itself fails, which is the read failing
        # rather than finding nothing.
        assert {:error, :unavailable} = SiteInstance.resolve("not-an-org-id")
        assert SiteInstance.active?("not-an-org-id")
      end)
    end

    test "the page's decryptability check agrees with the resolver", %{org: org} do
      row = instance!(org)
      assert SiteInstance.api_key_readable?(row)

      force_column!(row, :api_key_encrypted, :crypto.strong_rand_bytes(48))
      {:ok, [row]} = CMS.list_site_meilisearch(tenant: org, authorize?: false)
      refute SiteInstance.api_key_readable?(row)
    end
  end

  describe "the URL" do
    for url <- [
          "https://10.1.2.3",
          "https://127.0.0.1:7700",
          "https://169.254.169.254",
          "https://localhost:7700",
          "https://search.internal",
          "https://[::1]:7700"
        ] do
      test "refuses the private address #{url} at save", %{org: org} do
        assert {:error, error} =
                 CMS.save_site_meilisearch(%{@attrs | url: unquote(url)},
                   tenant: org,
                   authorize?: false
                 )

        assert Exception.message(error) =~ "url"
      end
    end

    test "refuses plain HTTP — the request carries a bearer key", %{org: org} do
      assert {:error, error} =
               CMS.save_site_meilisearch(%{@attrs | url: "http://search.site.example"},
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "must use HTTPS"
    end

    for url <- [
          "https://user:pw@search.site.example",
          "https://search.site.example/?a=1",
          "https://search.site.example/#x"
        ] do
      test "refuses #{url}", %{org: org} do
        assert {:error, error} =
                 CMS.save_site_meilisearch(%{@attrs | url: unquote(url)},
                   tenant: org,
                   authorize?: false
                 )

        assert Exception.message(error) =~ "user name, query string or fragment"
      end
    end

    test "keeps a path prefix — an instance behind a reverse proxy", %{org: org} do
      instance!(org, %{url: "https://site.example/meili/"})

      assert {:ok, %{url: "https://site.example/meili/"}} = SiteInstance.resolve(org.id)

      assert Meilisearch.ReqClient.join("https://site.example/meili/", "/indexes/x/search") ==
               "https://site.example/meili/indexes/x/search"
    end

    test "refuses an index name Meilisearch would refuse", %{org: org} do
      assert {:error, error} =
               CMS.save_site_meilisearch(%{@attrs | index: "no spaces"},
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "letters, digits, hyphens and underscores"
    end
  end

  describe "the key" do
    test "is stored encrypted, never as given", %{org: org} do
      row = instance!(org)

      assert is_binary(row.api_key_encrypted)
      refute row.api_key_encrypted =~ "site-key"
      assert {:ok, "site-key"} = Vault.decrypt(row.api_key_encrypted)
    end

    test "a blank key on update keeps the stored one", %{org: org} do
      row = instance!(org)

      updated =
        CMS.update_site_meilisearch!(row, %{index: "renamed", api_key: ""},
          tenant: org,
          authorize?: false
        )

      assert updated.index == "renamed"
      assert {:ok, "site-key"} = Vault.decrypt(updated.api_key_encrypted)
    end

    test "a new key replaces it", %{org: org} do
      row = instance!(org)

      updated =
        CMS.update_site_meilisearch!(row, %{api_key: "rotated"}, tenant: org, authorize?: false)

      assert {:ok, "rotated"} = Vault.decrypt(updated.api_key_encrypted)
    end

    test "switched on, it needs a URL, an index and a key", %{org: org} do
      assert {:error, error} =
               CMS.save_site_meilisearch(%{index: nil}, tenant: org, authorize?: false)

      message = Exception.message(error)
      assert message =~ "url"
      assert message =~ "index"
      assert message =~ "api_key"
    end

    test "switched off, it may be saved half-filled", %{org: org} do
      assert {:ok, _row} =
               CMS.save_site_meilisearch(%{enabled: false}, tenant: org, authorize?: false)
    end
  end

  describe "reindex on change" do
    test "saving, switching off and removing each enqueue a reindex of the site",
         %{org: org} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        row = instance!(org)
        assert_enqueued(worker: MeilisearchWorker, args: %{"op" => "reindex", "org_id" => org.id})

        KilnCMS.Repo.delete_all(Oban.Job)
        row = CMS.update_site_meilisearch!(row, %{enabled: false}, tenant: org, authorize?: false)
        assert_enqueued(worker: MeilisearchWorker, args: %{"op" => "reindex", "org_id" => org.id})

        KilnCMS.Repo.delete_all(Oban.Job)
        CMS.reset_site_meilisearch!(row, tenant: org, authorize?: false)
        assert_enqueued(worker: MeilisearchWorker, args: %{"op" => "reindex", "org_id" => org.id})
      end)
    end

    test "a refused save enqueues nothing", %{org: org} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:error, _} =
          CMS.save_site_meilisearch(%{@attrs | url: "https://10.0.0.1"},
            tenant: org,
            authorize?: false
          )

        refute_enqueued(worker: MeilisearchWorker)
      end)
    end

    test "pending/1 counts only this site's outstanding jobs", %{org: org, other: other} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _} = MeilisearchWorker.enqueue_reindex(org.id)
        {:ok, _} = MeilisearchWorker.enqueue_reindex(other.id)

        assert %{queued: 1, held: 0} = MeilisearchWorker.pending(org.id)
      end)
    end
  end
end
