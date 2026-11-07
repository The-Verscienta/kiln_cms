defmodule KilnCMSWeb.CustomFieldAliasesOrgTest do
  @moduledoc """
  Org scoping of `filter[x]` / `sort=x` aliases (#2292): a custom field defined
  for org A is unknown on org B's host. The alias plug resolves nothing itself;
  the preparation reads the registry under the request's tenant, which this
  proves over HTTP.

  `async: false`: orgs are created through `KilnCMS.OrgFixtures`, which the
  other cross-org suites also serialise.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS
  alias KilnCMSWeb.Tenant

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "alias-org-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp get_on(org, query) do
    conn = %{build_conn() | host: "#{org.slug}.#{Tenant.base_host()}"}

    conn =
      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> get("/api/json/posts?" <> query)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "a field defined in org A is not reachable by org B through filter[x] or sort=x" do
    actor = admin()
    a = org("alias-a")
    b = org("alias-b")
    price = "price#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{content_type: :post, name: price, label: "Price", field_type: :integer},
      actor: actor,
      tenant: a
    )

    publish = fn org, title, fields ->
      %{title: title, slug: "alias-#{System.unique_integer([:positive])}", custom_fields: fields}
      |> CMS.create_post!(actor: actor, tenant: org)
      |> CMS.publish_post!(%{}, actor: actor, tenant: org)
    end

    cheap = publish.(a, "Cheap", %{price => 5})
    dear = publish.(a, "Dear", %{price => 50})
    _theirs = publish.(b, "Theirs", %{})

    # Org A: the positive control.
    assert {200, body} = get_on(a, "filter[#{price}][gt]=10")
    assert Enum.map(body["data"], & &1["id"]) == [dear.id]

    assert {200, body} = get_on(a, "filter[#{price}][null]=false&sort=-#{price}")
    assert Enum.map(body["data"], & &1["id"]) == [dear.id, cheap.id]

    # Org B: the same requests name a field B does not have.
    for query <- ["filter[#{price}][gt]=10", "sort=#{price}"] do
      assert {400, body} = get_on(b, query)
      assert [%{"detail" => "unknown custom field" <> _}] = body["errors"]
    end
  end
end
