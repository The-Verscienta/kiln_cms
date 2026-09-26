defmodule KilnCMS.Forms.EmbedCeilingAutoTest do
  @moduledoc """
  An unset `EMBED_ORIGINS_LOCKED` is **auto** (#1618): the operator's ceiling
  over form framing is on if and only if more than one organization exists,
  and an explicit `true` or `false` still wins.

  Auto reads `KilnCMSWeb.Tenant.OrgCount`'s verdict — the one
  `TENANT_STRICT_HOST` reads (#1547) — so these tests drive that verdict the
  way `KilnCMSWeb.TenantStrictHostAutoTest` does: a real count for the
  one-org / two-org cases, a real create for the no-restart case, and `put/1`
  only for the state no test can reach through the database (`:unknown`).

  `config/test.exs` pins `:embed_origins` (the ceiling) to
  `["https://embedder.test"]` and `:embed_origins_locked` to `false`; see there
  for why the suite does not run on auto. `async: false` — both settings and
  the verdict are VM-global. Each test restores all three.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Forms.EmbedCeiling
  alias KilnCMS.Forms.EmbedPolicy
  alias KilnCMSWeb.Tenant
  alias KilnCMSWeb.Tenant.OrgCount

  @outside "https://partner.test"
  @inside "https://embedder.test"

  setup do
    lock = Application.get_env(:kiln_cms, :embed_origins_locked)
    ceiling = Application.get_env(:kiln_cms, :embed_origins)
    multi = Application.get_env(:kiln_cms, :multitenancy_enabled)
    verdict = OrgCount.verdict()

    on_exit(fn ->
      restore(:embed_origins_locked, lock)
      restore(:embed_origins, ceiling)
      restore(:multitenancy_enabled, multi)
      OrgCount.put(verdict)
    end)

    Application.put_env(:kiln_cms, :multitenancy_enabled, true)
    # Start from "nobody has counted", so a verdict another test left behind
    # cannot be what a test observes.
    OrgCount.put(:unknown)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp setting!(value), do: Application.put_env(:kiln_cms, :embed_origins_locked, value)

  defp admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "eca-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # A form in the default org whose own allowlist was saved while the cap was
  # off — the pre-upgrade row this issue is about. Saved under an explicit
  # `false` so the write is accepted whatever the verdict says.
  defp wide_form!(actor) do
    previous = Application.get_env(:kiln_cms, :embed_origins_locked)
    setting!(false)

    form =
      CMS.create_form!(
        %{
          name: "Contact",
          slug: "eca-#{System.unique_integer([:positive])}",
          success_message: "Thanks",
          embed_origins: [@inside, @outside]
        },
        actor: actor,
        tenant: Accounts.default_org_id()
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: actor,
      tenant: Accounts.default_org_id()
    )

    setting!(previous)
    form
  end

  # Through the action — `Ash.Seed` (the `org/1` fixture) bypasses the change
  # that moves the verdict, which is the point of the no-restart case.
  defp create_org(slug) do
    Accounts.create_organization(
      %{name: "Org #{slug}", slug: "#{slug}-#{System.unique_integer([:positive])}"},
      authorize?: false
    )
  end

  defp served(conn, form) do
    [_head, sources] =
      %{conn | host: Tenant.base_host()}
      |> unique_ip()
      |> get("/forms/#{form.slug}/embed")
      |> get_resp_header("content-security-policy")
      |> List.first()
      |> String.split("frame-ancestors ")

    sources
  end

  defp try_save(form, actor) do
    CMS.update_form(form, %{embed_origins: [@outside]},
      actor: actor,
      tenant: Accounts.default_org_id()
    )
  end

  describe "the setting" do
    test "unset, and any non-boolean, is auto" do
      Application.delete_env(:kiln_cms, :embed_origins_locked)
      assert EmbedCeiling.setting() == :auto

      setting!(:auto)
      assert EmbedCeiling.setting() == :auto

      setting!("yes")
      assert EmbedCeiling.setting() == :auto
    end

    test "true and false mean what they say" do
      setting!(true)
      assert EmbedCeiling.setting() == true

      setting!(false)
      assert EmbedCeiling.setting() == false
    end

    test "the shipped default is auto" do
      # config/test.exs pins `false` for the suite; the shipped default is what
      # config/config.exs says, and that is what #1618 changed.
      assert File.read!("config/config.exs") =~ "config :kiln_cms, :embed_origins_locked, :auto"
    end

    # The runtime reader must not write when the variable is unset — `flag/2`
    # would replace `:auto` with a hard `false` on every deployment.
    test "config/runtime reads it with fetch/1, not flag/2" do
      source = File.read!("config/runtime/cross_origin.exs")
      assert source =~ ~s|Env.fetch("EMBED_ORIGINS_LOCKED")|
      refute source =~ ~s|Env.flag("EMBED_ORIGINS_LOCKED"|
    end
  end

  describe "auto with one organization" do
    setup do
      setting!(:auto)
      assert OrgCount.refresh() == 1, "another test leaked an org through the action"
      :ok
    end

    test "is uncapped: the stored list is served whole and a wider write is accepted",
         %{conn: conn} do
      actor = admin()
      form = wide_form!(actor)

      assert OrgCount.verdict() == :single
      refute EmbedCeiling.locked?()

      assert EmbedPolicy.effective(form).embed_origins == [@inside, @outside]
      assert served(conn, form) =~ @outside
      assert {:ok, _} = try_save(form, actor)
      assert EmbedCeiling.stored_overreach() == %{forms: 0, sites: 0}
    end
  end

  describe "auto with two organizations" do
    setup do: setting!(:auto)

    test "is capped when the second one existed at boot", %{conn: conn} do
      actor = admin()
      form = wide_form!(actor)
      org("eca-boot")

      assert OrgCount.refresh() == 2
      assert EmbedCeiling.locked?()

      assert EmbedPolicy.effective(form).embed_origins == [@inside]
      refute served(conn, form) =~ @outside
      assert {:error, %Ash.Error.Invalid{}} = try_save(form, actor)
    end

    test "caps right after the second org's create, with no restart", %{conn: conn} do
      actor = admin()
      form = wide_form!(actor)

      assert OrgCount.refresh() == 1
      refute EmbedCeiling.locked?()
      assert served(conn, form) =~ @outside

      assert {:ok, _second} = create_org("eca-create")

      assert EmbedCeiling.locked?()
      # The served header, the builder's view of it, and the write all move
      # together, on the same node, without anything being restarted.
      refute served(conn, form) =~ @outside
      assert served(conn, form) =~ @inside
      assert EmbedPolicy.effective(form).embed_origins == [@inside]
      assert {:error, %Ash.Error.Invalid{} = error} = try_save(form, actor)
      assert Exception.message(error) =~ @outside

      # The row itself is untouched: the cap clamps on the way out.
      reloaded = Ash.get!(CMS.Form, form.id, authorize?: false, tenant: Accounts.default_org_id())
      assert reloaded.embed_origins == [@inside, @outside]
    end

    test "the create that turns it on warns about the lists it cuts down" do
      form_actor = admin()
      _form = wide_form!(form_actor)
      assert OrgCount.refresh() == 1

      log = capture_log(fn -> assert {:ok, _} = create_org("eca-warn") end)

      assert log =~ "the second on this deployment"
      assert log =~ "1 form allowlist(s)"
      assert log =~ "EMBED_ORIGINS_LOCKED is unset"
      assert log =~ "EMBED_ORIGINS_LOCKED=false"
    end

    test "with EMBED_ORIGINS unset, the cap closes every cross-site embed", %{conn: conn} do
      actor = admin()
      form = wide_form!(actor)
      org("eca-closed")
      OrgCount.refresh()
      Application.put_env(:kiln_cms, :embed_origins, [])

      assert EmbedCeiling.locked?()
      assert EmbedPolicy.effective(form).embed_origins == []
      assert String.trim(served(conn, form)) =~ ~r/\A'self'(;|\z)/

      assert EmbedCeiling.stored_overreach() == %{forms: 1, sites: 0}
      assert EmbedCeiling.overreach_warning() =~ "same-origin only"
    end
  end

  describe "an explicit setting wins" do
    test "false with two organizations is uncapped", %{conn: conn} do
      actor = admin()
      form = wide_form!(actor)
      setting!(false)
      assert OrgCount.refresh() == 1

      assert {:ok, _} = create_org("eca-off")

      assert OrgCount.verdict() == :multi
      refute EmbedCeiling.locked?()
      assert served(conn, form) =~ @outside
      assert {:ok, _} = try_save(form, actor)
      assert EmbedCeiling.stored_overreach() == %{forms: 0, sites: 0}
      assert EmbedCeiling.overreach_warning() == nil
    end

    test "true with one organization is capped" do
      setting!(true)
      OrgCount.put(:single)

      assert EmbedCeiling.locked?()
    end
  end

  describe "the verdict" do
    setup do: setting!(:auto)

    # Nobody has counted (boot with the database down). Uncapped-but-actually
    # -multi serves a tenant's list wider than the operator allows; capped-but
    # -actually-single narrows embeds until the recount lands.
    test "an unknown count fails closed" do
      OrgCount.put(:unknown)
      assert EmbedCeiling.locked?()
    end
  end

  describe "stored lists over the ceiling" do
    setup do
      setting!(true)
      :ok
    end

    test "are counted per rung, and only when they reach outside" do
      actor = admin()
      _wide = wide_form!(actor)

      org = org("eca-site")

      setting!(false)

      CMS.save_site_embed_settings!(%{embed_origins: [@outside]},
        actor: actor,
        tenant: org
      )

      setting!(true)

      assert EmbedCeiling.stored_overreach() == %{forms: 1, sites: 1}

      warning = EmbedCeiling.overreach_warning()
      assert warning =~ "1 form allowlist(s) and 1 site-wide"
      assert warning =~ "EMBED_ORIGINS_LOCKED=true"
      refute warning =~ "same-origin only"
      # Counts only: the warning never names an origin or an org.
      refute warning =~ @outside
      refute warning =~ org.slug
    end

    # docs/forms.md promises an admin whose saved list is now over the ceiling
    # can still edit the form: a save that re-submits the unchanged list is
    # not a change to it, so the ceiling validation does not fire.
    test "other edits still save, even re-submitting the unchanged list" do
      actor = admin()
      form = wide_form!(actor)

      assert {:ok, %{name: "Renamed"}} =
               CMS.update_form(form, %{name: "Renamed", embed_origins: [@inside, @outside]},
                 actor: actor,
                 tenant: Accounts.default_org_id()
               )
    end

    test "a ceiling of everything cuts nothing" do
      _wide = wide_form!(admin())
      Application.put_env(:kiln_cms, :embed_origins, :all)

      assert EmbedCeiling.stored_overreach() == %{forms: 0, sites: 0}
      assert EmbedCeiling.overreach_warning() == nil
    end

    test "a list inside the ceiling is not counted" do
      setting!(false)

      CMS.create_form!(
        %{
          name: "Inside",
          slug: "eca-in-#{System.unique_integer([:positive])}",
          success_message: "Thanks",
          embed_origins: [@inside]
        },
        actor: admin(),
        tenant: Accounts.default_org_id()
      )

      setting!(true)
      assert EmbedCeiling.stored_overreach() == %{forms: 0, sites: 0}
    end
  end

  describe "the /editor/system panel" do
    @password "password123456"

    setup %{conn: conn} do
      email = "eca-admin-#{System.unique_integer([:positive])}@example.com"

      Ash.Seed.seed!(Accounts.User, %{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

      strategy = AshAuthentication.Info.strategy!(Accounts.User, :password)

      {:ok, user} =
        AshAuthentication.Strategy.action(strategy, :sign_in, %{
          "email" => email,
          "password" => @password
        })

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)

      # The page's upstream-release check runs async; answer it offline so it
      # neither reaches the network nor crashes looking for a stub.
      Kiln.Updates.clear_cache()
      on_exit(&Kiln.Updates.clear_cache/0)
      Req.Test.stub(Kiln.Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      %{conn: conn, user: user}
    end

    test "shows the counts while stored lists are cut down", %{conn: conn, user: user} do
      _wide = wide_form!(user)
      org("eca-panel")
      setting!(:auto)
      OrgCount.refresh()

      {:ok, lv, html} = live(conn, ~p"/editor/system")
      # Let the release check finish while its stub is still installed.
      _ = render_async(lv)

      assert html =~ "Some sites can no longer embed forms"
      assert html =~ "1 form allowlist(s) and 0 site-wide"
      assert html =~ "EMBED_ORIGINS_LOCKED is unset"
      refute html =~ @outside
    end

    test "stays quiet when nothing is cut down", %{conn: conn, user: user} do
      _wide = wide_form!(user)
      setting!(false)

      {:ok, lv, html} = live(conn, ~p"/editor/system")
      # Let the release check finish while its stub is still installed.
      _ = render_async(lv)

      assert html =~ "This instance"
      refute html =~ "Some sites can no longer embed forms"
    end

    # `/editor/forms/settings` used to read the env var itself, so an unset
    # setting on a multi-org deployment would enforce a cap the page denied.
    test "the org embed settings page says the cap is on under auto", %{conn: conn} do
      org("eca-settings")
      setting!(:auto)
      OrgCount.refresh()

      {:ok, _lv, html} = live(conn, ~p"/editor/forms/settings")
      assert html =~ "capped which sites may embed forms"

      setting!(false)
      {:ok, _lv, html} = live(conn, ~p"/editor/forms/settings")
      refute html =~ "capped which sites may embed forms"
    end
  end
end
