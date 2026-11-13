defmodule KilnCMSWeb.LinkFieldJsonApiTest do
  @moduledoc """
  A hostile address posted to the `link` custom field over real JSON:API HTTP
  (#2435): `javascript:`, a protocol-relative `//host`, `data:` and `tel:` are
  refused with a 400 and nothing is stored; a safe address round-trips.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "lfj-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.create_field_definition!(
      %{content_type: :page, name: "source", label: "Source", field_type: :link},
      actor: admin
    )

    key =
      admin.id
      |> Accounts.mint_api_key!(
        "link-field",
        DateTime.add(DateTime.utc_now(), 1, :day),
        %{access: :read_write},
        actor: admin
      )
      |> Ash.Resource.get_metadata(:plaintext_api_key)

    %{key: key}
  end

  defp post_page(key, link) do
    attrs = %{
      title: "Link",
      slug: "lfj-#{System.unique_integer([:positive])}",
      custom_fields: %{"source" => link}
    }

    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/api/json/pages", Jason.encode!(%{data: %{type: "page", attributes: attrs}}))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  for url <- ["javascript:alert(1)", "//evil.example/x", "data:text/html,hi", "tel:+15551234"] do
    test "#{url} is refused over HTTP", %{key: key} do
      assert {status, %{"errors" => [_ | _]}} = post_page(key, %{"url" => unquote(url)})
      assert status in 400..422
    end
  end

  test "a safe address is stored and served", %{key: key} do
    assert {201, body} = post_page(key, %{"url" => "https://example.com/a", "target" => "_blank"})

    assert %{"url" => "https://example.com/a", "target" => "_blank", "rel" => rel} =
             body["data"]["attributes"]["custom_fields"]["source"]

    assert rel =~ "noopener"
  end

  # #2739: a reference's link field filtered with an object operand used to
  # reach `to_string/1` under `ilike` — a 500 on a public read.
  describe "a link-field filter with an operand of the wrong shape" do
    setup %{key: key} do
      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "lfj-ref-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      cta =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "cta#{System.unique_integer([:positive])}",
            label: "Call to action",
            field_type: :reference,
            target_type: "page"
          },
          actor: admin
        )

      for {name, type} <- [{"label", :string}, {"until", :datetime}] do
        CMS.create_field_definition!(
          %{link_of_id: cta.id, name: name, label: name, field_type: type},
          actor: admin
        )
      end

      %{cta: cta.name, key: key}
    end

    defp get_pages(query, key) do
      conn =
        build_conn()
        |> put_req_header("accept", @accept)
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/json/pages?" <> query)

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    test "an object operand is a 400 invalid_argument for every operator", %{cta: cta, key: key} do
      for {link, op} <- [{"label", "ilike"}, {"label", "eq"}, {"until", "eq"}, {"until", "gte"}] do
        assert {400, body} =
                 get_pages("custom_filter[#{cta}.link.#{link}][#{op}][x]=1", key)

        assert [%{"code" => "invalid_argument", "detail" => detail}] = body["errors"]

        assert detail =~
                 ~s(#{op} on link field "#{cta}.link.#{link}" takes a value, not a nested filter)
      end
    end

    test "a list operand beside ilike is a 400; in still takes one", %{cta: cta, key: key} do
      assert {400, body} = get_pages("custom_filter[#{cta}.link.label][ilike][]=a", key)
      assert [%{"detail" => detail}] = body["errors"]
      assert detail =~ ~s(ilike on link field "#{cta}.link.label" takes one value, not a list)

      assert {200, _body} = get_pages("custom_filter[#{cta}.link.label][in][]=a", key)
      assert {200, _body} = get_pages("custom_filter[#{cta}.link.label][ilike]=a%25", key)
    end

    test "an object item inside in names the link field, like its other operators", %{
      cta: cta,
      key: key
    } do
      assert {400, body} = get_pages("custom_filter[#{cta}.link.label][in][0][x]=1", key)
      assert [%{"code" => "invalid_argument", "detail" => detail}] = body["errors"]

      assert detail =~
               ~s(in on link field "#{cta}.link.label" takes a value, not a nested filter)
    end
  end
end
