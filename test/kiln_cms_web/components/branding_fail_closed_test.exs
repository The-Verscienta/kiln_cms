defmodule KilnCMSWeb.BrandingFailClosedTest do
  @moduledoc """
  A layout with no resolved organization renders unbranded, not the default
  org's identity (#701).

  `Branding.for_org(nil)` resolves the **default** organization. That is right
  for a caller that deliberately asks for the instance-wide identity, and wrong
  for one that never found out — on a tenant host it renders another site's name
  and logo, which is the leak #48 exists to prevent and the one #680 and #558
  closed for the token preview and the error pages.

  The two states are distinguishable: a hook that ran always *assigns*
  `:current_org`, so a **missing key** means no hook ran. That is precisely what
  a url-less LiveView join leaves behind, since it skips its `live_session`'s
  whole `on_mount` list.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Branding
  alias KilnCMSWeb.Layouts

  # A branded org, so "default org's identity" and "unbranded" are visibly
  # different strings. Without this the test would pass on a deployment whose
  # default org happens to carry no branding row — i.e. for the wrong reason.
  setup do
    org_id = Accounts.default_org_id()

    {:ok, _row} =
      KilnCMS.CMS.save_site_branding(
        %{site_name: "Acme Press", logo_url: "/acme.svg"},
        tenant: org_id,
        authorize?: false
      )

    KilnCMS.Cache.bust_branding(org_id)
    on_exit(fn -> KilnCMS.Cache.bust_branding(org_id) end)

    %{org_id: org_id}
  end

  # Exactly how Phoenix invokes a `layout:` — `Phoenix.LiveView.Renderer` puts
  # `:inner_content` on the socket's assigns and hands them to
  # `Phoenix.Template.render/4`, which calls the function directly. Notably NOT
  # as `<Layouts.auth />`: that path applies the `attr` defaults, which would
  # supply the very key whose absence is the thing under test.
  defp layout_assigns(extra \\ []) do
    Enum.into(extra, %{__changed__: %{}, inner_content: []})
  end

  describe "brand_or_unbranded/1" do
    test "falls back to the stock brand when nothing assigned an org" do
      brand = Layouts.brand_or_unbranded(%{})

      assert brand == Branding.defaults()
      refute brand.site_name == Branding.for_org(nil).site_name
    end

    test "resolves normally when the key is present, including a legitimate nil", %{
      org_id: org_id
    } do
      # A *present* `nil` is a caller that looked and found no org — the mail
      # senders and `SignInAlert` do this on purpose — so it keeps resolving to
      # the instance identity rather than being punished for the absent case.
      assert Layouts.brand_or_unbranded(%{current_org: nil}) == Branding.for_org(nil)
      assert Layouts.brand_or_unbranded(%{current_org: org_id}).site_name == "Acme Press"
    end
  end

  describe "the auth layout" do
    test "renders another org's name when the hook ran and resolved it", %{org_id: org_id} do
      html = rendered_to_string(Layouts.auth(layout_assigns(current_org: org_id)))

      assert html =~ "Acme Press"
    end

    test "renders unbranded when no hook ran at all" do
      # The #701 scenario: a url-less join to one of AshAuthentication's own
      # LiveViews skips `:assign_current_org`, so the assign never arrives. The
      # page must not answer that by wearing the default org's identity.
      # Called directly, the way Phoenix invokes a `layout:` — not as
      # `<Layouts.auth />`, whose `attr` default would supply the very key whose
      # absence is the thing under test.
      html = rendered_to_string(Layouts.auth(layout_assigns()))

      refute html =~ "Acme Press"
      assert html =~ Branding.defaults().site_name
    end
  end
end
