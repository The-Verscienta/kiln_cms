defmodule KilnCMSWeb.FormEmbedDefaultTest do
  @moduledoc """
  The **shipped** framing default for embeddable forms (#562), exercised through
  the real request pipeline.

  `config/test.exs` pins `:embed_origins` to an allowlist so the rest of the
  suite asserts a configured policy deterministically — which leaves the one
  thing #562 is about, the `Application.get_env/3` fallback taken when
  `EMBED_ORIGINS` is unset, covered by nothing. Reverting
  `KilnCMSWeb.Embed`'s default to `:all` would then serve `frame-ancestors *` to
  the whole internet again with a green suite.

  So this module clears the key instead of passing a setting as an argument, and
  asserts on the header the controller actually puts. It is `async: false`
  because `Application.delete_env/2` is global — the repo's established shape for
  config-dependent tests (see `test/kiln_cms/unsplash_test.exs`).
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMSWeb.Embed

  setup do
    previous = Application.get_env(:kiln_cms, :embed_origins)
    Application.delete_env(:kiln_cms, :embed_origins)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:kiln_cms, :embed_origins)
        value -> Application.put_env(:kiln_cms, :embed_origins, value)
      end
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fed-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form! do
    actor = admin()

    form =
      CMS.create_form!(
        %{
          name: "Contact us",
          slug: "fed-#{System.unique_integer([:positive])}",
          success_message: "Merci!",
          active: true
        },
        actor: actor
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: actor
    )

    form
  end

  defp unique_ip(conn) do
    Map.put(conn, :remote_ip, {127, 3, rem(System.unique_integer([:positive]), 250), 1})
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  test "with EMBED_ORIGINS unset the embed page is same-origin only", %{conn: conn} do
    form = form!()
    conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

    assert html_response(conn, 200) =~ "Contact us"
    assert String.ends_with?(csp(conn), "frame-ancestors 'self'")
    refute csp(conn) =~ "frame-ancestors *"
  end

  test "the embedded thank-you page is same-origin only too", %{conn: conn} do
    form = form!()

    conn =
      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{"email" => "a@b.com", "_kiln_embed" => "1"})

    assert html_response(conn, 200) =~ "Merci!"
    assert String.ends_with?(csp(conn), "frame-ancestors 'self'")
  end

  test "the framable 404 is same-origin only too", %{conn: conn} do
    conn = conn |> unique_ip() |> get("/forms/does-not-exist/embed")

    assert html_response(conn, 404) =~ "Form not found"
    assert String.ends_with?(csp(conn), "frame-ancestors 'self'")
  end

  test "the module reports embedding as closed", %{conn: _conn} do
    assert Embed.frame_ancestors() == "'self'"
    refute Embed.cross_site?()
    assert Embed.allowed_origins_label() == nil
  end
end
