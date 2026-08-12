defmodule KilnCMS.FormFixtures do
  @moduledoc """
  Test scaffolding for embeddable forms (#1134).

  Three test files each carried their own `admin/0` and `form!/2`, differing
  only in the email prefix. This module collapses the three copies. Rate-bucket
  separation is `KilnCMSWeb.ConnCase.unique_ip/1`'s job (#936) — already
  imported into every `ConnCase` test, so it is not re-exported here.
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
  a map (`%{embed_origins: [...]}`) or a keyword list (`form_embed_test` calls
  `form!(active: false)`, a single argument that binds to `attrs`, not `opts`).
  `opts` may contain `:actor` and `:tenant` (as `form_embed_origins_test` does).

  Creates the form and its required email field, returning the form.
  """
  @spec form!(map() | keyword(), keyword()) :: KilnCMS.CMS.Form.t()
  def form!(attrs \\ %{}, opts \\ [])
  def form!(attrs, opts) when is_list(attrs), do: form!(Map.new(attrs), opts)

  def form!(attrs, opts) do
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
end
