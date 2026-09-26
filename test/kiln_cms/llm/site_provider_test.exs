defmodule KilnCMS.LLM.SiteProviderTest do
  @moduledoc """
  A site's own AI provider (#1557): the row (`KilnCMS.CMS.SiteAiProvider`) and
  the resolver that decides which provider, model and key a site's AI requests
  use (`KilnCMS.LLM.SiteProvider`).

  What each group pins, because each is a way this could quietly go wrong:

    * **precedence** — a row switched on wins for every feature, a blank model
      switches that feature off rather than handing it to the operator, none
      or switched off is the operator's config, and one site's row never
      touches another site;
    * **fail direction** — a row that can't be read, or a key that can't be
      decrypted, is an error, never the operator's route;
    * **the key** — encrypted, write-only, kept on a blank save, dropped when
      the destination changes;
    * **the tenant boundary** — the endpoint is https and SSRF-checked, and
      only an admin of the site may read or write the row.

  The facades' use of the resolver, and the isolation of the operator's
  credentials, are in `KilnCMS.LLM.SiteProviderIsolationTest` (global env, so
  not async).
  """
  use KilnCMS.DataCase, async: true

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteAiProvider
  alias KilnCMS.Keys.Vault
  alias KilnCMS.LLM.Route
  alias KilnCMS.LLM.SiteProvider

  setup do
    %{org: KilnCMS.OrgFixtures.org("ai"), other: KilnCMS.OrgFixtures.org("ai-other")}
  end

  defp provider!(org, attrs \\ %{}) do
    %{
      provider: :anthropic,
      api_key: "sk-site-key",
      seo_model: "claude-sonnet-5",
      assist_model: "claude-sonnet-5",
      ask_model: "claude-haiku-5"
    }
    |> Map.merge(attrs)
    |> CMS.save_site_ai_provider!(tenant: org, authorize?: false)
  end

  defp force_column!(row, column, value) do
    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "site_ai_providers", where: r.id == type(^row.id, :binary_id)),
        set: [{column, value}]
      )
  end

  describe "precedence" do
    test "no site, or something that is not an org id, is the operator's", _ctx do
      assert SiteProvider.resolve(nil, :seo) == :operator
      assert SiteProvider.resolve("org-1", :assist) == :operator
      assert SiteProvider.resolve(%{id: "org-1", name: "Default"}, :ask) == :operator
    end

    test "a site with no row is the operator's", %{org: org} do
      assert SiteProvider.resolve(org.id, :seo) == :operator
    end

    test "a row switched off is the operator's", %{org: org} do
      provider!(org, %{enabled: false})
      assert SiteProvider.resolve(org.id, :seo) == :operator
    end

    test "a row switched on is the site's provider, model and key", %{org: org} do
      provider!(org)

      assert {:site, %Route{} = route} = SiteProvider.resolve(org.id, :ask)
      assert route.source == :site
      assert route.provider == :anthropic
      assert route.model == "anthropic:claude-haiku-5"
      assert route.api_key == "sk-site-key"
      # The provider's own API root, spelled out — never left for `req_llm` to
      # fill from the operator's config.
      assert route.base_url =~ "api.anthropic.com"
      assert SiteProvider.endpoint_host(route) == "api.anthropic.com"
    end

    test "an organization struct resolves like its id", %{org: org} do
      provider!(org)
      assert {:site, _route} = SiteProvider.resolve(org, :seo)
    end

    test "a blank model switches that feature off — it is not handed to the operator",
         %{org: org} do
      provider!(org, %{ask_model: nil})

      assert SiteProvider.resolve(org.id, :ask) == :off
      assert {:site, _route} = SiteProvider.resolve(org.id, :seo)
    end

    test "one site's row never reaches another site", %{org: org, other: other} do
      provider!(org)
      assert SiteProvider.resolve(other.id, :seo) == :operator
    end

    test "an OpenAI-compatible endpoint keeps its own URL and bare model name", %{org: org} do
      provider!(org, %{
        provider: :openai_compatible,
        base_url: "https://llm.site.example/v1",
        api_key: nil
      })

      assert {:site, route} = SiteProvider.resolve(org.id, :seo)
      assert route.model == "claude-sonnet-5"
      assert route.base_url == "https://llm.site.example/v1"
      assert route.api_key == nil
      assert SiteProvider.endpoint_host(route) == "llm.site.example"
    end
  end

  describe "fail direction" do
    test "an undecryptable key is an error, not the operator's route", %{org: org} do
      row = provider!(org)
      # What a SECRET_KEY_BASE rotation leaves behind.
      force_column!(row, :api_key_encrypted, :crypto.strong_rand_bytes(48))

      assert {:error, :credentials_unreadable} = SiteProvider.resolve(org.id, :seo)
    end

    test "a hosted provider whose key went missing out of band is an error", %{org: org} do
      row = provider!(org)
      force_column!(row, :api_key_encrypted, nil)

      assert {:error, :credentials_unreadable} = SiteProvider.resolve(org.id, :assist)
    end

    test "a row that can't be read is an error, not the operator's route", %{org: org} do
      provider!(org)
      parent = self()

      # A process outside this test's sandbox: its read fails the way a pool
      # timeout or a mid-deploy missing table does — it raises.
      spawn(fn -> send(parent, {:resolved, SiteProvider.resolve(org.id, :seo)}) end)

      assert_receive {:resolved, {:error, :unavailable}}, 5_000
    end

    test "the page's decryptability check agrees with the resolver", %{org: org} do
      row = provider!(org)
      assert SiteProvider.key_readable?(row)

      force_column!(row, :api_key_encrypted, :crypto.strong_rand_bytes(48))
      {:ok, [row]} = CMS.list_site_ai_provider(tenant: org, authorize?: false)
      refute SiteProvider.key_readable?(row)
    end

    test "every error has words for the editor" do
      for reason <- [:unavailable, :credentials_unreadable] do
        assert SiteProvider.describe_error(reason) =~ "its"
      end
    end
  end

  describe "the key" do
    test "is stored encrypted, never as given", %{org: org} do
      row = provider!(org)

      refute row.api_key_encrypted == "sk-site-key"
      assert {:ok, "sk-site-key"} = Vault.decrypt(row.api_key_encrypted)
    end

    test "is left out of inspect output, so out of logs", %{org: org} do
      row = provider!(org)
      refute inspect(row) =~ "api_key_encrypted"

      {:site, route} = SiteProvider.resolve(org.id, :seo)
      refute inspect(route) =~ "sk-site-key"
    end

    test "a blank key on update keeps the stored one", %{org: org} do
      row = provider!(org)

      row =
        CMS.update_site_ai_provider!(row, %{api_key: "", seo_model: "claude-opus-5"},
          authorize?: false
        )

      assert row.seo_model == "claude-opus-5"
      assert {:ok, "sk-site-key"} = Vault.decrypt(row.api_key_encrypted)
    end

    test "a new key replaces it", %{org: org} do
      row = provider!(org)
      row = CMS.update_site_ai_provider!(row, %{api_key: "sk-new"}, authorize?: false)

      assert {:ok, "sk-new"} = Vault.decrypt(row.api_key_encrypted)
    end

    test "changing the provider without a new key is refused, and never sends the old one",
         %{org: org} do
      row = provider!(org)

      assert {:error, error} =
               CMS.update_site_ai_provider(row, %{provider: :openai}, authorize?: false)

      assert Exception.message(error) =~ "entered again"

      {:ok, [row]} = CMS.list_site_ai_provider(tenant: org, authorize?: false)
      assert row.provider == :anthropic
    end

    test "changing the endpoint drops the key the old endpoint was given", %{org: org} do
      row =
        provider!(org, %{
          provider: :openai_compatible,
          base_url: "https://llm.site.example/v1",
          api_key: "sk-for-site-endpoint"
        })

      # Another admin of the site points it somewhere else. The key was never
      # shown to them; it must not follow.
      row =
        CMS.update_site_ai_provider!(row, %{base_url: "https://elsewhere.example/v1"},
          authorize?: false
        )

      assert row.api_key_encrypted == nil
      assert {:site, %Route{api_key: nil}} = SiteProvider.resolve(org.id, :seo)
    end

    test "a hosted provider needs one", %{org: org} do
      assert {:error, error} =
               CMS.save_site_ai_provider(%{provider: :openai, seo_model: "gpt-5-mini"},
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "required"
    end

    test "an OpenAI-compatible endpoint may have none", %{org: org} do
      assert %SiteAiProvider{api_key_encrypted: nil} =
               provider!(org, %{
                 provider: :openai_compatible,
                 base_url: "https://llm.site.example/v1",
                 api_key: nil
               })
    end

    test "a hosted provider keeps no stale endpoint", %{org: org} do
      row = provider!(org, %{base_url: "https://ignored.example/v1"})
      assert row.base_url == nil
    end
  end

  describe "the endpoint" do
    test "is required for an OpenAI-compatible provider", %{org: org} do
      assert {:error, _error} =
               CMS.save_site_ai_provider(%{provider: :openai_compatible, seo_model: "m"},
                 tenant: org,
                 authorize?: false
               )
    end

    test "must be https — the request carries the key", %{org: org} do
      assert {:error, error} =
               CMS.save_site_ai_provider(
                 %{provider: :openai_compatible, base_url: "http://llm.site.example/v1"},
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "https://"
    end

    for url <- [
          "https://10.0.0.5/v1",
          "https://127.0.0.1:11434/v1",
          "https://169.254.169.254/latest",
          "https://localhost:8000/v1"
        ] do
      test "refuses the private endpoint #{url}", %{org: org} do
        assert {:error, _error} =
                 CMS.save_site_ai_provider(
                   %{provider: :openai_compatible, base_url: unquote(url), seo_model: "m"},
                   tenant: org,
                   authorize?: false
                 )

        assert {:ok, []} = CMS.list_site_ai_provider(tenant: org, authorize?: false)
      end
    end

    test "refuses a query string, which would ride on every request", %{org: org} do
      assert {:error, _error} =
               CMS.save_site_ai_provider(
                 %{provider: :openai_compatible, base_url: "https://llm.site.example/v1?k=x"},
                 tenant: org,
                 authorize?: false
               )
    end

    test "a model name with spaces is refused", %{org: org} do
      assert {:error, _error} =
               CMS.save_site_ai_provider(
                 %{provider: :anthropic, api_key: "k", seo_model: "claude sonnet"},
                 tenant: org,
                 authorize?: false
               )
    end
  end

  describe "authorization" do
    test "is read by admins only — it names the site's AI account" do
      assert SiteAiProvider.__kiln_org_settings__().read == :admin
    end

    test "a site admin may write it; an editor of the same site may neither read nor write it",
         %{org: org} do
      admin = user_with_tier(org, :admin)
      editor = user_with_tier(org, :editor)

      assert {:ok, _row} =
               CMS.save_site_ai_provider(
                 %{provider: :anthropic, api_key: "sk-admin", seo_model: "claude-sonnet-5"},
                 actor: admin,
                 tenant: org
               )

      assert {:ok, []} = CMS.list_site_ai_provider(actor: editor, tenant: org)
      refute CMS.can_save_site_ai_provider?(editor, tenant: org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_ai_provider(
                 %{provider: :anthropic, api_key: "sk-editor", seo_model: "x"},
                 actor: editor,
                 tenant: org
               )
    end

    test "an admin of another site cannot see this site's row", %{org: org, other: other} do
      provider!(org)
      other_admin = user_with_tier(other, :admin)

      assert {:ok, []} = CMS.list_site_ai_provider(actor: other_admin, tenant: other)
    end
  end

  defp user_with_tier(org, tier) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "ai-#{tier}-#{System.unique_integer([:positive])}@example.com",
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
end
