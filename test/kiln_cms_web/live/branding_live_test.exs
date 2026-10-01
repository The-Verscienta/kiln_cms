defmodule KilnCMSWeb.BrandingLiveTest do
  @moduledoc """
  White-label branding settings (#48): the admin auth matrix, a real save, and
  the cross-org write boundary.

  The last of those is the important one. `Checks.OrgAdmin` resolves the actor's
  tier against the *request's* org, which is only safe because `SiteBranding` is
  tenant-scoped — a tenant-less resource would resolve every actor to the default
  org and let one site's admin rebrand every other site (the hazard documented on
  `KilnCMS.Mail.Settings`). These tests are the regression guard for that.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    %{org: org}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/branding")
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/branding")

      assert flash["error"] =~ "admin access"
    end

    test "loads for a platform admin", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      assert html =~ "Branding"
      assert html =~ "Site name"
    end

    test "loads for an org admin on their own site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_org_admin(user, org)

      {:ok, _lv, html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/branding")

      assert html =~ "Site name"
    end
  end

  describe "saving" do
    test "persists the tokens for the current site only", %{conn: conn, org: org} do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      {:ok, lv, _html} =
        conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      lv
      |> form("#branding-form",
        branding: %{site_name: "Acme Docs", brand_color: "#0f62fe", logo_url: "/uploads/acme.png"}
      )
      |> render_submit()

      assert {:ok, [row]} = CMS.list_site_branding(tenant: org, authorize?: false)
      assert row.site_name == "Acme Docs"
      assert row.brand_color == "#0f62fe"

      # The other site is untouched.
      assert {:ok, []} = CMS.list_site_branding(tenant: other, authorize?: false)
      assert KilnCMS.Branding.for_org(other).site_name == "KilnCMS"
    end

    test "persists the public theme and nav slots (#1318)", %{conn: conn, org: org} do
      menu =
        CMS.create_menu!(%{key: "main", name: "Main", locale: KilnCMS.I18n.default_locale()},
          actor: authed_user(:admin),
          tenant: org
        )

      on_exit(fn -> KilnCMS.Cache.bump_menus_generation(org.id) end)

      {:ok, lv, html} =
        conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      # The configured menu is offered as a slot option.
      assert html =~ "Main (main)"

      lv
      |> form("#branding-form",
        branding: %{theme: "editorial", header_menu_key: menu.key}
      )
      |> render_submit()

      assert {:ok, [row]} = CMS.list_site_branding(tenant: org, authorize?: false)
      assert row.theme == :editorial
      assert row.header_menu_key == "main"
      assert row.footer_menu_key == nil

      brand = KilnCMS.Branding.for_org(org)
      assert brand.theme == :editorial
      assert brand.header_menu_key == "main"
    end

    test "surfaces a validation error instead of writing", %{conn: conn, org: org} do
      {:ok, lv, _html} =
        conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/branding")

      html =
        lv
        |> form("#branding-form", branding: %{brand_color: "#fff} body{display:none}"})
        |> render_submit()

      assert html =~ "hex colour"
      assert {:ok, []} = CMS.list_site_branding(tenant: org, authorize?: false)
    end
  end

  # #629. The measurement and the URL have to be written by the same save: an
  # `app_icon_size` left over from a previous icon is a wrong `sizes` in the
  # manifest, and a wrong `sizes` removes the install prompt outright.
  describe "the app icon is measured on save" do
    setup %{conn: conn, org: org} do
      %{conn: conn |> org_conn(org) |> log_in(authed_user(:admin))}
    end

    # A successful save reloads the page (#1810), so the flash is read off the
    # page the redirect lands on; a refused save re-renders in place.
    defp save_icon(ctx, url) do
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

      lv
      |> form("#branding-form", branding: %{site_name: "Icon Co", app_icon_url: url})
      |> render_submit()
      |> case do
        html when is_binary(html) ->
          html

        {:error, {:redirect, _}} = redirect ->
          html = reloaded_html(redirect, ctx.conn)
          html
      end
    end

    defp row!(org) do
      {:ok, [row]} = CMS.list_site_branding(tenant: org, authorize?: false)
      row
    end

    test "a verified icon stores the measured edge", ctx do
      stub_icon(512, 512)

      save_icon(ctx, "/uploads/icon.png")

      row = row!(ctx.org)
      assert row.app_icon_url == "/uploads/icon.png"
      assert row.app_icon_size == 512
    end

    test "an icon that fails verification is still saved, but with no size", ctx do
      # Deliberate: rejecting the field would make a briefly-down CDN throw away
      # what the admin typed. Withholding the *size* is what keeps the unusable
      # icon out of the manifest.
      stub_icon(300, 300)

      html = save_icon(ctx, "/uploads/small.png")

      row = row!(ctx.org)
      assert row.app_icon_url == "/uploads/small.png"
      assert row.app_icon_size == nil

      # And the admin is told which of the reasons it was. Asserted on the
      # MEASURED edge, not on "at least 512" — the form's own static hint
      # carries that phrase on every render, so it would pass with the whole
      # explanation deleted.
      assert html =~ "300×300"
    end

    test "a non-square icon names both dimensions", ctx do
      stub_icon(1200, 300)

      html = save_icon(ctx, "/uploads/wordmark.png")

      assert row!(ctx.org).app_icon_size == nil
      assert html =~ "1200×300"
    end

    test "clearing the URL clears the size with it", ctx do
      stub_icon(512, 512)
      save_icon(ctx, "/uploads/icon.png")
      assert row!(ctx.org).app_icon_size == 512

      save_icon(ctx, "")

      row = row!(ctx.org)
      assert row.app_icon_url == nil
      # The size is a claim ABOUT the URL. Left behind, it would be a claim
      # about nothing, and the next icon would inherit it.
      assert row.app_icon_size == nil
    end

    test "a URL the image policy forbids is never fetched", ctx do
      # No stub is installed, so a fetch here would go to the real adapter. The
      # save must fail on the validation, not on a network round trip: the
      # probe must not become a way to make the server dial an arbitrary host.
      html = save_icon(ctx, "https://evil.example.com/icon.png")

      assert html =~ "not allowed"
      assert {:ok, []} = CMS.list_site_branding(tenant: ctx.org, authorize?: false)
    end
  end

  # #1810: the colour lives in the root layout's `<style>`, which a LiveView
  # re-render never touches — so a save that only flashed left the old colour
  # on screen until a manual reload.
  describe "the brand colour takes effect on save (#1810)" do
    setup %{conn: conn, org: org} do
      %{conn: conn |> org_conn(org) |> log_in(authed_user(:admin))}
    end

    test "saving reloads the page, and the reloaded page carries the new colour", ctx do
      {:ok, colour} = KilnCMS.Branding.Color.derive("#333333")
      {:ok, lv, html} = live(ctx.conn, ~p"/editor/branding")
      refute html =~ "--color-primary:#{colour.light_primary}"

      result =
        lv
        |> form("#branding-form", branding: %{brand_color: "#333333"})
        |> render_submit()

      assert {:error, {:redirect, %{to: "/editor/branding"}}} = result

      html = reloaded_html(result, ctx.conn)
      assert html =~ "Branding saved."
      # Both halves of the token pair: the dark one is the lifted shade.
      assert html =~ "--color-primary:#{colour.light_primary}"
      assert html =~ ~s([data-theme="dark"]{--color-primary:#{colour.dark_primary})
    end

    test "resetting reloads the page back to the stock colour", ctx do
      {:ok, colour} = KilnCMS.Branding.Color.derive("#333333")
      CMS.save_site_branding!(%{brand_color: "#333333"}, tenant: ctx.org, authorize?: false)

      {:ok, lv, html} = live(ctx.conn, ~p"/editor/branding")
      assert html =~ "--color-primary:#{colour.light_primary}"

      result = lv |> element("button", "Reset to defaults") |> render_click()
      assert {:error, {:redirect, %{to: "/editor/branding"}}} = result

      html = reloaded_html(result, ctx.conn)
      refute html =~ "--color-primary:#{colour.light_primary}"
    end

    test "the preview shows a button and a link in light and dark mode as you type", ctx do
      {:ok, colour} = KilnCMS.Branding.Color.derive("#333333")
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")
      refute has_element?(lv, "#brand-colour-preview")

      lv |> form("#branding-form", branding: %{brand_color: "#333333"}) |> render_change()

      assert lv
             |> element("#brand-preview-light span", "Button")
             |> render() =~ "background-color:#{colour.light_primary}"

      assert lv
             |> element("#brand-preview-dark span", "Button")
             |> render() =~ "background-color:#{colour.dark_primary}"

      assert lv |> element("#brand-preview-dark span", "A link") |> render() =~
               "color:#{colour.dark_ink}"
    end

    test "the help text says where the colour is used", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/branding")

      assert html =~ "buttons, links and highlights"
      assert html =~ "In dark mode a lighter shade is used."
    end
  end

  # #1811: every image field can be filled from the media library or by an
  # upload, not only by pasting a URL copied from /media.
  describe "image fields (#1811)" do
    # A minimal valid 1x1 PNG.
    @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
           8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207,
           0, 0, 0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

    setup %{conn: conn, org: org} do
      root = Path.join(System.tmp_dir!(), "kiln_brandlive_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

      on_exit(fn ->
        File.rm_rf!(root)
        Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      end)

      admin = authed_user(:admin)
      %{admin: admin, conn: conn |> org_conn(org) |> log_in(admin)}
    end

    defp media!(org, filename, content_type) do
      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: filename,
        url: "/uploads/#{System.unique_integer([:positive])}-#{filename}",
        content_type: content_type,
        org_id: org.id
      })
    end

    defp field_value(lv, field) do
      lv
      |> element("#branding_#{field}")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("value")
      |> List.first()
    end

    for field <- ~w(logo_url favicon_url social_image_url app_icon_url) do
      test "#{field}: choosing from the library fills the field", ctx do
        field = unquote(field)
        item = media!(ctx.org, "brand.png", "image/png")
        {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

        lv |> element("#image-field-#{field} button", "Choose from library") |> render_click()
        assert has_element?(lv, "#image-picker-dialog")

        lv |> element("#image-picker-dialog button[phx-value-id='#{item.id}']") |> render_click()

        refute has_element?(lv, "#image-picker-dialog")
        assert field_value(lv, field) == item.url
        assert has_element?(lv, "#image-field-#{field}-preview[src='#{item.url}']")
      end

      test "#{field}: an upload goes into the media library and fills the field", ctx do
        field = unquote(field)
        upload = String.replace_suffix(field, "_url", "_upload") |> String.to_existing_atom()
        {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

        lv
        |> file_input("#branding-form", upload, [
          %{name: "brand-#{field}.png", content: @png, type: "image/png"}
        ])
        |> render_upload("brand-#{field}.png")

        assert {:ok, [item]} =
                 CMS.list_media_items(tenant: ctx.org, authorize?: false)

        assert item.filename == "brand-#{field}.png"
        assert item.uploaded_by_id == ctx.admin.id
        assert field_value(lv, field) == item.url
      end
    end

    test "the picker offers only the formats the field takes", ctx do
      png = media!(ctx.org, "mark.png", "image/png")
      jpeg = media!(ctx.org, "photo.jpg", "image/jpeg")
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

      lv |> element("#image-field-favicon_url button", "Choose from library") |> render_click()
      assert has_element?(lv, "#image-picker-dialog button[phx-value-id='#{png.id}']")
      refute has_element?(lv, "#image-picker-dialog button[phx-value-id='#{jpeg.id}']")

      render_click(lv, "close_picker", %{})

      lv |> element("#image-field-logo_url button", "Choose from library") |> render_click()
      assert has_element?(lv, "#image-picker-dialog button[phx-value-id='#{jpeg.id}']")
    end

    test "the picker searches the library", ctx do
      wanted = media!(ctx.org, "wordmark.png", "image/png")
      other = media!(ctx.org, "holiday.png", "image/png")
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

      lv |> element("#image-field-logo_url button", "Choose from library") |> render_click()
      lv |> form("#media-browser-filter", %{q: "wordmark"}) |> render_change()

      assert has_element?(lv, "#image-picker-dialog button[phx-value-id='#{wanted.id}']")
      refute has_element?(lv, "#image-picker-dialog button[phx-value-id='#{other.id}']")
    end

    test "a picked item is resolved on the server: another site's image is refused", ctx do
      elsewhere = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(elsewhere.id) end)
      foreign = media!(elsewhere, "theirs.png", "image/png")
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

      lv |> element("#image-field-logo_url button", "Choose from library") |> render_click()
      html = render_click(lv, "pick_image", %{"id" => foreign.id, "url" => "/uploads/forged.png"})

      assert html =~ "no longer in the media library"
      assert field_value(lv, "logo_url") in [nil, ""]
    end

    test "a JPEG renamed .png is stored but not used as the favicon", ctx do
      {:ok, image} = Image.new(4, 4, color: :red)
      {:ok, jpeg} = Image.write(image, :memory, suffix: ".jpg")
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

      html =
        lv
        |> file_input("#branding-form", :favicon_upload, [
          %{name: "favicon.png", content: jpeg, type: "image/png"}
        ])
        |> render_upload("favicon.png")

      assert html =~ "The favicon must be a PNG image."
      assert field_value(lv, "favicon_url") in [nil, ""]
    end

    test "a picked image is saved with the rest of the branding", ctx do
      item = media!(ctx.org, "logo.png", "image/png")
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")

      lv |> element("#image-field-logo_url button", "Choose from library") |> render_click()
      lv |> element("#image-picker-dialog button[phx-value-id='#{item.id}']") |> render_click()

      lv |> form("#branding-form") |> render_submit()

      assert {:ok, [row]} = CMS.list_site_branding(tenant: ctx.org, authorize?: false)
      assert row.logo_url == item.url
    end

    test "Remove empties the field", ctx do
      CMS.save_site_branding!(%{logo_url: "/uploads/old.png"}, tenant: ctx.org, authorize?: false)
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/branding")
      assert field_value(lv, "logo_url") == "/uploads/old.png"

      lv |> element("#image-field-logo_url button", "Remove") |> render_click()
      assert field_value(lv, "logo_url") in [nil, ""]
    end
  end

  describe "cross-org write boundary" do
    test "an admin of one site cannot write another site's branding", %{org: org} do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      user = authed_user(:editor)
      grant_org_admin(user, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_branding(%{site_name: "Hijacked"}, actor: user, tenant: other)
    end

    test "a DEFAULT-org admin cannot write another site's branding" do
      # The specific shape of the Mail.Settings hazard: without the tenant
      # attribute, `OrgAdmin` would resolve this actor to the default org and
      # pass on every other org's row.
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      user = authed_user(:editor)
      grant_org_admin(user, Accounts.default_org())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_branding(%{site_name: "Hijacked"}, actor: user, tenant: other)
    end

    test "an org editor is not an org admin", %{org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_branding(%{site_name: "Nope"}, actor: user, tenant: org)
    end
  end

  # `/uploads/...` is read through `KilnCMS.Storage`, not over HTTP, so the
  # fixture is a real file at a real key — libvips reads its actual header, which
  # is the whole point of the probe.
  defp stub_icon(width, height) do
    {:ok, image} = Image.new(width, height, color: :green)
    path = Path.join(System.tmp_dir!(), "icon-#{System.unique_integer([:positive])}.png")
    {:ok, _image} = Image.write(image, path)

    for key <- ~w(icon.png small.png wordmark.png) do
      {:ok, _stored} = KilnCMS.Storage.store(key, path)
      on_exit(fn -> KilnCMS.Storage.delete(key) end)
    end

    File.rm(path)
    :ok
  end

  # A save ends in a full `redirect/2` (#1810): follow it as a plain GET, so
  # the HTML includes the root layout — where the brand `<style>` lives — and
  # the flash carried across the redirect.
  defp reloaded_html({:error, {:redirect, _}} = redirect, conn) do
    {:ok, conn} = follow_redirect(redirect, conn)
    html_response(conn, 200)
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Branding Site",
      slug: "brandlive-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_org_admin(user, org), do: grant_tier(user, org, :admin)

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "brandlive-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
