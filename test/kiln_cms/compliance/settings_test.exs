defmodule KilnCMS.Compliance.SettingsTest do
  @moduledoc """
  The claim-checking resolve chain (#857): per-site `SiteCompliance` row over
  `config :kiln_cms, KilnCMS.Compliance` over nothing at all.

  The point of the issue is what a config-only feature does on a shared install
  (#336): one tenant's claims vocabulary, and one tenant's hard publish gate,
  applied to every other site with no override. So the tests that matter here
  are the cross-org ones — a green single-org suite is exactly what the old
  shape had.

  `async: false` — these mutate application env and the shared Cachex.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings

  setup do
    original = Application.get_env(:kiln_cms, Compliance, [])
    Application.put_env(:kiln_cms, Compliance, [])
    bust(Accounts.default_org_id())

    on_exit(fn ->
      Application.put_env(:kiln_cms, Compliance, original)
      bust(Accounts.default_org_id())
    end)

    org = org("compliance")
    on_exit(fn -> bust(org.id) end)

    %{org: org, admin: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "compliance-settings-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp bust(org_id), do: KilnCMS.Cache.bust_compliance(org_id)

  defp put_config(opts), do: Application.put_env(:kiln_cms, Compliance, opts)

  defp save(%{org: org, admin: admin}, attrs) do
    {:ok, row} = CMS.save_site_compliance(attrs, actor: admin, tenant: org)
    row
  end

  describe "the resolve chain" do
    test "a site with no row inherits the operator config exactly", %{org: org} do
      put_config(enabled: true, require_at_publish: true, disclaimer: "Not medical advice.")

      settings = Settings.for_org(org)

      assert settings.enabled?
      assert settings.require_at_publish?
      assert settings.disclaimer == "Not medical advice."
      assert settings.rules == Compliance.default_rules()
    end

    test "everything is off when neither layer says anything", %{org: org} do
      settings = Settings.for_org(org)

      refute settings.enabled?
      refute settings.require_at_publish?
      assert settings.disclaimer == nil
    end

    test "a row overrides the operator config", ctx do
      put_config(enabled: true, require_at_publish: true)
      save(ctx, %{enabled: false, require_at_publish: false})

      settings = Settings.for_org(ctx.org)

      refute settings.enabled?
      refute settings.require_at_publish?
    end

    # The inversion the issue is about: a deployment-wide gate that a tenant
    # cannot decline. If this ever regresses, one clinic's decision that
    # "cures" cannot ship refuses every other site's publishes again.
    test "a site can decline a publish gate the operator turned on", ctx do
      put_config(enabled: true, require_at_publish: true)
      save(ctx, %{enabled: true, require_at_publish: false})

      refute Settings.for_org(ctx.org).require_at_publish?
      # And the operator's default still applies to a site that said nothing.
      assert Settings.for_org(org("compliance")).require_at_publish?
    end

    test "the gate is read through enabled, so it is inert on its own", ctx do
      save(ctx, %{enabled: false, require_at_publish: true})

      refute Settings.for_org(ctx.org).require_at_publish?
    end

    test "a blank disclaimer falls through to the operator's", ctx do
      put_config(enabled: true, disclaimer: "Operator text.")
      save(ctx, %{enabled: true, disclaimer: "   "})

      assert Settings.for_org(ctx.org).disclaimer == "Operator text."
    end

    test "a site's disclaimer wins over the operator's", ctx do
      put_config(enabled: true, disclaimer: "Operator text.")
      save(ctx, %{enabled: true, disclaimer: "Site text."})

      assert Settings.for_org(ctx.org).disclaimer == "Site text."
    end

    test "accepts an org struct, a bare id or nil, and degrades on anything else" do
      org = org("compliance")
      on_exit(fn -> bust(org.id) end)

      for arg <- [org, org.id, nil] do
        assert %Settings{rules: rules} = Settings.for_org(arg)
        assert is_list(rules)
      end

      # A socket, a changeset, a stray tuple: answering with the DEFAULT org's
      # settings would be reading one tenant's vocabulary for another.
      assert Settings.for_org({:not, :an, :org}) == Settings.unavailable()
    end
  end

  describe "a site's own vocabulary" do
    test "its phrases become a rule of their own, carrying its severity", ctx do
      put_config(enabled: true)
      save(ctx, %{enabled: true, phrases: ["banishes toxins"], phrase_severity: :error})

      settings = Settings.for_org(ctx.org)

      assert %{code: :site_claim, severity: :error, phrases: ["banishes toxins"]} =
               List.last(settings.rules)

      assert %{site_claim: ["banishes toxins"]} =
               Compliance.scan("This tea banishes toxins.", settings.rules)
    end

    # A blank line in a hand-typed list is not an error. Ash's string type
    # trims `"   "` to nil, so without normalization the save fails with "no
    # nil values" — a constraint no admin can see.
    test "blank and duplicate phrases are dropped rather than rejected", ctx do
      put_config(enabled: true)
      row = save(ctx, %{enabled: true, phrases: ["   ", "detoxes you", "detoxes you", ""]})

      assert row.phrases == ["detoxes you"]
    end

    test "a list of nothing but blanks leaves the shipped pack alone", ctx do
      put_config(enabled: true)
      save(ctx, %{enabled: true, phrases: ["   "]})

      assert Settings.for_org(ctx.org).rules == Compliance.default_rules()
    end

    test "a site can drop the deployment's rules and keep only its own", ctx do
      put_config(enabled: true)
      save(ctx, %{enabled: true, use_shared_rules: false, phrases: ["banishes toxins"]})

      settings = Settings.for_org(ctx.org)

      assert [%{code: :site_claim}] = settings.rules
      assert %{} == Compliance.scan("This is FDA approved.", settings.rules)
    end

    # A site with no rules at all reports every document as unchecked rather
    # than clean — `Checks.Claims` gets an empty rule list, scans nothing, and
    # the panel says so. What it must never do is pass.
    test "a site can end up with no rules, and that is not a clean bill", ctx do
      put_config(enabled: true)
      save(ctx, %{enabled: true, use_shared_rules: false, phrases: []})

      settings = Settings.for_org(ctx.org)

      assert settings.rules == []
      assert %{} == Compliance.scan("This is FDA approved.", settings.rules)
    end

    # The English-only test is about the *rules*, not the config key: a site
    # that typed its own phrases meant them for its own content, whatever
    # language that is in.
    test "a site's own phrases are judged in every locale", ctx do
      put_config(enabled: true)
      save(ctx, %{enabled: true, phrases: ["approuvé par la fda"]})

      settings = Settings.for_org(ctx.org)

      refute settings.shipped_pack?
      assert Settings.judgeable_locale?(settings, "fr")
    end

    test "the shipped pack alone is English only", %{org: org} do
      put_config(enabled: true)

      settings = Settings.for_org(org)

      assert settings.shipped_pack?
      assert Settings.judgeable_locale?(settings, "en-GB")
      refute Settings.judgeable_locale?(settings, "fr")
    end
  end

  describe "cross-org isolation" do
    test "one site's vocabulary never reaches another's documents", ctx do
      other = org("compliance")
      on_exit(fn -> bust(other.id) end)

      put_config(enabled: true)
      save(ctx, %{enabled: true, phrases: ["banishes toxins"], phrase_severity: :error})

      mine = Settings.for_org(ctx.org)
      theirs = Settings.for_org(other)

      assert %{site_claim: _} = Compliance.scan("It banishes toxins.", mine.rules)
      assert %{} == Compliance.scan("It banishes toxins.", theirs.rules)
    end

    test "one site turning the panel off never turns another's off", ctx do
      other = org("compliance")
      on_exit(fn -> bust(other.id) end)

      put_config(enabled: true)
      save(ctx, %{enabled: false})

      refute Settings.for_org(ctx.org).enabled?
      assert Settings.for_org(other).enabled?
    end

    test "saving twice for one site upserts rather than creating a second row", ctx do
      save(ctx, %{enabled: true, phrases: ["one"]})
      save(ctx, %{enabled: true, phrases: ["two"]})

      assert {:ok, [row]} = CMS.list_site_compliance(tenant: ctx.org, authorize?: false)
      assert row.phrases == ["two"]
    end

    # Every column here has a default, and a default is applied on the create
    # side of an upsert — so unlike `FeedSettings`, a partial save is a full
    # one with the rest reset. Pinned because `/editor/compliance` relies on
    # the opposite never being assumed: its one-click "turn it on" sends the
    # whole set for exactly this reason.
    test "a save writes every column, so callers must send the whole set", ctx do
      save(ctx, %{enabled: true, phrases: ["one"], phrase_severity: :error})
      save(ctx, %{enabled: false})

      assert {:ok, [row]} = CMS.list_site_compliance(tenant: ctx.org, authorize?: false)
      refute row.enabled
      assert row.phrases == []
      assert row.phrase_severity == :warning
    end
  end

  describe "caching" do
    test "a save is visible immediately rather than after the TTL", ctx do
      put_config(enabled: true)
      assert Settings.for_org(ctx.org).enabled?

      save(ctx, %{enabled: false})

      refute Settings.for_org(ctx.org).enabled?
    end

    test "a destroy puts the site back on the operator defaults", ctx do
      put_config(enabled: true)
      save(ctx, %{enabled: false})
      refute Settings.for_org(ctx.org).enabled?

      {:ok, [row]} = CMS.list_site_compliance(tenant: ctx.org, authorize?: false)
      :ok = CMS.reset_site_compliance(row, actor: ctx.admin, tenant: ctx.org)

      assert Settings.for_org(ctx.org).enabled?
    end
  end

  describe "unavailable/0" do
    # The axis that can turn a transient read error into a site that cannot
    # publish at all. Refusing on rules nobody could read is not a stricter
    # gate, it is a wrong one.
    test "keeps the operator's advisory answers but never the publish gate" do
      put_config(enabled: true, require_at_publish: true, disclaimer: "Not medical advice.")

      unavailable = Settings.unavailable()

      assert unavailable.enabled?
      assert unavailable.disclaimer == "Not medical advice."
      assert unavailable.rules == Compliance.default_rules()
      refute unavailable.require_at_publish?
    end
  end
end
