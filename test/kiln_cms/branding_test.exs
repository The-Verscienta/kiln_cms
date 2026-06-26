defmodule KilnCMS.BrandingTest do
  @moduledoc """
  White-label branding tokens fall back to stock defaults and reflect config.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Branding

  setup do
    original = Application.get_env(:kiln_cms, :branding)
    on_exit(fn -> Application.put_env(:kiln_cms, :branding, original) end)
    :ok
  end

  test "defaults to stock KilnCMS branding when unconfigured" do
    Application.put_env(:kiln_cms, :branding, [])

    assert Branding.site_name() == "KilnCMS"
    assert Branding.logo_url() == "/images/logo.svg"
    assert Branding.primary_color() == nil
    assert Branding.primary_color_style() == nil
  end

  test "reflects configured brand tokens" do
    Application.put_env(:kiln_cms, :branding,
      site_name: "Acme CMS",
      logo_url: "/images/acme.svg",
      primary_color: "oklch(55% 0.2 264)"
    )

    assert Branding.site_name() == "Acme CMS"
    assert Branding.logo_url() == "/images/acme.svg"
    assert Branding.primary_color() == "oklch(55% 0.2 264)"
    assert Branding.primary_color_style() == "--color-primary: oklch(55% 0.2 264);"
  end

  test "treats a blank primary color as unset" do
    Application.put_env(:kiln_cms, :branding, primary_color: "")

    assert Branding.primary_color() == nil
    assert Branding.primary_color_style() == nil
  end
end
