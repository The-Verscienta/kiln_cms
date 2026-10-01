defmodule KilnCMSWeb.TenantProdBaseUrlTest do
  @moduledoc """
  `KilnCMSWeb.Tenant.base_url/1` under a production-shaped runtime config
  (#1833): the default org links to `https://<PHX_HOST>` and every other org to
  `https://<slug>.<PHX_HOST>` — no `localhost`, no `:4000`.

  The config is the one `config/runtime.exs` actually produces for a `:prod`
  evaluation, not a hand-written value, so a fragment that stops setting
  `:public_base_url` fails here as well as in the runtime config test.

  `async: false`: it swaps VM-wide application env and environment variables.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("y", 64),
    "PHX_HOST" => "cms.example.com"
  }

  @vars Map.keys(@env) ++ ~w(PUBLIC_BASE_URL TENANT_BASE_HOST)

  setup do
    saved_env = Map.new(@vars, &{&1, System.get_env(&1)})

    saved_app =
      Map.new([:public_base_url, :tenant_base_host], &{&1, Application.fetch_env(:kiln_cms, &1)})

    on_exit(fn ->
      Enum.each(saved_env, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      Enum.each(saved_app, fn
        {key, {:ok, value}} -> Application.put_env(:kiln_cms, key, value)
        {key, :error} -> Application.delete_env(:kiln_cms, key)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)
    Enum.each(@env, fn {k, v} -> System.put_env(k, v) end)

    config =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Config.Reader.read!(@runtime, env: :prod) end)
      |> elem(0)
      |> Keyword.fetch!(:kiln_cms)

    Application.put_env(:kiln_cms, :public_base_url, config[:public_base_url])
    Application.put_env(:kiln_cms, :tenant_base_host, config[:tenant_base_host])
    :ok
  end

  test "the default org links to https://<PHX_HOST>" do
    assert Tenant.base_url(Accounts.default_org()) == "https://cms.example.com"
    assert Tenant.base_url(nil) == "https://cms.example.com"
  end

  test "another org links to https://<slug>.<PHX_HOST>, with no port" do
    o = org("acme")
    assert Tenant.base_url(o) == "https://#{o.slug}.cms.example.com"
    assert Tenant.base_url(o.id) == "https://#{o.slug}.cms.example.com"
  end

  test "a custom domain keeps the production scheme" do
    o = org("vanity", custom_domain: "www.acme-vanity.com")
    assert Tenant.base_url(o) == "https://www.acme-vanity.com"
  end
end
