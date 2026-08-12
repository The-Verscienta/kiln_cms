defmodule KilnCMS.FormFixtures do
  @moduledoc """
  Test scaffolding for embeddable forms (#1134).

  Three test files each carried their own `admin/0`, `form!/2` and `unique_ip/1`,
  differing only in the email prefix and the second octet of the fake IP. The IP
  one is the sharp edge: the octet was hand-picked per file to keep rate buckets
  from colliding, so adding a fourth file meant checking which octets were already
  taken — invisible until a test flaked under load.

  This module collapses the three copies and makes bucket separation a property
  of the helper rather than of whoever remembered. `unique_ip/1` derives a distinct
  bucket per *test* (not per file) via `System.unique_integer/1` and `phash2` on
  the test pid, so a fourth caller needs no coordination.
  """

  alias KilnCMS.CMS

  @doc "An admin user for form tests."
  @spec admin() :: KilnCMS.Accounts.User.t()
  def admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "form-fixture-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  @doc """
  Create a form for tests.

  `attrs` are merged into the default `%{name, slug, success_message}` — pass
  `%{embed_origins: [...]}` or `%{active: false}` there. `opts` may contain
  `:actor` and `:tenant` (as `form_embed_origins_test` does) or `:active`
  (as `form_embed_test` does for backwards compatibility).

  Creates the form and its required email field, returning the form.
  """
  @spec form!(map(), keyword()) :: KilnCMS.CMS.Form.t()
  def form!(attrs \\ %{}, opts \\ []) do
    # Backwards compat: `form_embed_test` called `form!(active: false)` with no
    # attrs map, so an `active` in `opts` is really an attr.
    {active_opt, opts} = Keyword.pop(opts, :active)
    attrs = if is_nil(active_opt), do: attrs, else: Map.put(attrs, :active, active_opt)

    actor = Keyword.get(opts, :actor) || admin()
    tenant = Keyword.get(opts, :tenant)

    form_attrs =
      Map.merge(
        %{
          name: "Contact us",
          slug: "form-#{System.unique_integer([:positive])}",
          success_message: "Merci!",
          active: true
        },
        attrs
      )

    create_opts =
      [actor: actor]
      |> then(fn o -> if tenant, do: Keyword.put(o, :tenant, tenant), else: o end)

    form = CMS.create_form!(form_attrs, create_opts)

    field_opts = if tenant, do: [actor: actor, tenant: tenant], else: [actor: actor]

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      field_opts
    )

    form
  end

  @doc """
  Put a distinct fake IP on `conn` so rate buckets never cross tests.

  Delegates to `KilnCMSWeb.ConnCase.unique_ip/1` (#936) — the shared helper that
  already derives a distinct bucket per test via `RateLimitHelpers`. Kept here
  for convenience so form tests can import one module for all three helpers.
  """
  @spec unique_ip(Plug.Conn.t()) :: Plug.Conn.t()
  def unique_ip(conn), do: KilnCMSWeb.ConnCase.unique_ip(conn)
end
