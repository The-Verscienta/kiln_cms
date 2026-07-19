defmodule KilnCMSWeb.PresentationTest do
  @moduledoc """
  `KilnCMSWeb.Presentation` (#355) — building the external front end's preview
  URL from a template, and deriving its origin for postMessage validation.
  """
  # async: false — mutates the global :presentation_preview_url config.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.Presentation

  setup do
    on_exit(fn -> Application.delete_env(:kiln_cms, :presentation_preview_url) end)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pres-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp post do
    CMS.create_post!(%{title: "T", slug: "pres-#{System.unique_integer([:positive])}"},
      actor: admin()
    )
  end

  test "unconfigured → nil URL and not configured?" do
    refute Presentation.configured?()
    assert Presentation.preview_url(ContentTypes.get(:post), post()) == nil
  end

  test "substitutes placeholders in a template" do
    Application.put_env(
      :kiln_cms,
      :presentation_preview_url,
      "https://front.example.com{path}?kilnPreview=1"
    )

    p = post()
    ct = ContentTypes.get(:post)

    url = Presentation.preview_url(ct, p)

    assert url ==
             "https://front.example.com#{ContentTypes.public_prefix(ct)}/#{p.slug}?kilnPreview=1"

    assert Presentation.configured?()
  end

  test "substitutes {type}/{slug}/{locale}" do
    Application.put_env(
      :kiln_cms,
      :presentation_preview_url,
      "https://f.example.com/{locale}/{type}/{slug}"
    )

    p = post()
    url = Presentation.preview_url(ContentTypes.get(:post), p)
    assert url == "https://f.example.com/en/post/#{p.slug}"
  end

  test "a bare base URL gets {path} appended" do
    Application.put_env(:kiln_cms, :presentation_preview_url, "https://front.example.com/")
    p = post()
    ct = ContentTypes.get(:post)

    assert Presentation.preview_url(ct, p) ==
             "https://front.example.com#{ContentTypes.public_prefix(ct)}/#{p.slug}"
  end

  test "frontend_origin strips the path/placeholders to the origin" do
    Application.put_env(
      :kiln_cms,
      :presentation_preview_url,
      "https://front.example.com:8443/{path}?x=1"
    )

    assert Presentation.frontend_origin() == "https://front.example.com:8443"

    Application.put_env(
      :kiln_cms,
      :presentation_preview_url,
      "https://front.example.com/blog/{slug}"
    )

    assert Presentation.frontend_origin() == "https://front.example.com"
  end

  test "disabled feature flag makes it unconfigured" do
    Application.put_env(:kiln_cms, :presentation_preview_url, "https://f.example.com{path}")
    Application.put_env(:kiln_cms, :visual_editing_enabled, false)
    on_exit(fn -> Application.delete_env(:kiln_cms, :visual_editing_enabled) end)
    refute Presentation.configured?()
  end
end
