defmodule KilnCMS.I18n.FallbackTest do
  @moduledoc """
  The fallback-chain rules (`KilnCMS.I18n.Fallback`) and the settings row
  behind them. The test config runs `en`, `fr` and `es`.

  `async: false`: two tests put the operator's `:i18n` config, which every
  concurrent delivery test reads.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS
  alias KilnCMS.I18n.Fallback
  alias KilnCMS.I18n.Fallback.Chains

  defp chains(explicit), do: %Chains{explicit: explicit}

  describe "chain/4" do
    test "starts with the requested locale, then the default when nothing is configured" do
      assert Fallback.chain(chains(%{}), "es") == ["es", "en"]
      assert Fallback.chain(chains(%{}), "en") == ["en"]
    end

    test "takes a configured chain as written — no silent last hop to the default" do
      assert Fallback.chain(chains(%{"es" => ["fr"]}), "es") == ["es", "fr"]
      assert Fallback.chain(chains(%{"es" => ["fr", "en"]}), "es") == ["es", "fr", "en"]
    end

    test "an empty chain never falls back" do
      assert Fallback.chain(chains(%{"es" => []}), "es") == ["es"]
    end

    test "drops a locale the deployment does not run, and never repeats one" do
      assert Fallback.chain(chains(%{"es" => ["de", "fr", "fr", "es"]}), "es") == ["es", "fr"]
    end

    test ":none and {:only, _} narrow the chain whatever the site says" do
      site = chains(%{"es" => ["fr", "en"]})

      assert Fallback.chain(site, "es", :none) == ["es"]
      assert Fallback.chain(site, "es", {:only, "en"}) == ["es", "en"]
      assert Fallback.chain(site, "es", {:only, "es"}) == ["es"]
    end

    test "navigation's implicit_default?: false takes only a configured chain" do
      assert Fallback.chain(chains(%{}), "es", :site, implicit_default?: false) == ["es"]

      assert Fallback.chain(chains(%{"es" => ["fr"]}), "es", :site, implicit_default?: false) ==
               ["es", "fr"]
    end

    # The degraded answer is the requested locale alone: a record found there
    # is right under every chain, and a miss is never cached — so nothing a
    # degraded walk leaves in the delivery cache can be wrong once the row is
    # readable again.
    test "an unreadable settings row falls back to nothing, for that request" do
      assert Fallback.unavailable().degraded?
      assert Fallback.chain(Fallback.unavailable(), "es") == ["es"]
    end
  end

  describe "the two layers" do
    setup do
      original = Application.get_env(:kiln_cms, :i18n)
      on_exit(fn -> Application.put_env(:kiln_cms, :i18n, original) end)
      :ok
    end

    test "the operator config is the default, and a site row replaces it whole" do
      Application.put_env(
        :kiln_cms,
        :i18n,
        Keyword.put(Application.get_env(:kiln_cms, :i18n), :fallbacks, %{"es" => ["fr"]})
      )

      assert Fallback.chain(Fallback.defaults(), "es") == ["es", "fr"]

      # `nil` inherits; `%{}` is the site saying "no chains", so `es` takes the
      # implicit default instead of the operator's `fr`.
      assert Fallback.chain(Fallback.for_row(%{fallbacks: nil}), "es") == ["es", "fr"]
      assert Fallback.chain(Fallback.for_row(%{fallbacks: %{}}), "es") == ["es", "en"]
    end

    test "a malformed operator value degrades to no chains rather than raising" do
      Application.put_env(
        :kiln_cms,
        :i18n,
        Keyword.put(Application.get_env(:kiln_cms, :i18n), :fallbacks, "es:fr")
      )

      assert Fallback.defaults().explicit == %{}
    end
  end

  describe "chains/1 and effective/1" do
    test "resolve per site" do
      site = org("fallback-chains")
      on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(site.id) end)

      CMS.save_site_locale_settings!(%{fallbacks: %{"es" => ["fr"], "fr" => []}},
        authorize?: false,
        tenant: site.id
      )

      assert Fallback.effective(site.id) == %{"en" => [], "fr" => [], "es" => ["fr"]}
      assert Fallback.chain(site, "es") == ["es", "fr"]
    end
  end

  describe "SiteLocaleSettings validation" do
    setup do
      site = org("fallback-validation")
      on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(site.id) end)
      %{site: site}
    end

    defp save(site, fallbacks),
      do:
        CMS.save_site_locale_settings(%{fallbacks: fallbacks}, authorize?: false, tenant: site.id)

    test "accepts supported locales, an empty chain, and nil", %{site: site} do
      assert {:ok, _} = save(site, %{"es" => ["fr", "en"], "fr" => []})
      assert {:ok, %{fallbacks: nil}} = save(site, nil)
    end

    for {label, fallbacks, message} <- [
          {"an unsupported key", %{"de" => ["en"]}, "not a locale this site runs"},
          {"an unsupported chain entry", %{"es" => ["fr_CA"]}, "not a locale this site runs"},
          {"a chain naming its own locale", %{"es" => ["es"]}, "names es itself"},
          {"a repeated locale", %{"es" => ["fr", "fr"]}, "names a locale twice"},
          {"a chain that is not a list", %{"es" => "fr"}, "must be a list"}
        ] do
      test "refuses #{label}", %{site: site} do
        assert {:error, error} = save(site, unquote(Macro.escape(fallbacks)))
        assert Exception.message(error) =~ unquote(message)
      end
    end

    test "only an org admin may write the row", %{site: site} do
      editor =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "fallback-ed-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_locale_settings(%{fallbacks: %{"es" => []}},
                 actor: editor,
                 tenant: site.id
               )
    end
  end
end
