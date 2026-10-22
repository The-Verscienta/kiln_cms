defmodule KilnCMSWeb.ArtifactFieldsTest do
  @moduledoc """
  `GET /api/content/:type/:slug?fields=…` — a sparse fieldset on the fired
  `json` artifact, for clients on constrained networks.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.TypedFixtures

  alias KilnCMS.CMS
  alias KilnCMSWeb.ArtifactFields

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fields-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  setup do
    admin = admin()
    n = System.unique_integer([:positive])
    price = "price_#{n}"
    colour = "colour_#{n}"

    for name <- [price, colour] do
      CMS.create_field_definition!(
        %{content_type: :post, name: name, label: name, field_type: :text},
        actor: admin
      )
    end

    post =
      CMS.create_post!(
        %{
          title: "Sparse",
          slug: "fields-#{n}",
          custom_fields: %{price => "12", colour => "red"},
          blocks:
            typed_blocks([%{type: :heading, content: "Hi", data: %{"level" => 1}, order: 0}])
        },
        actor: admin
      )
      |> CMS.publish_post!(actor: admin)

    # Firing is async (#201): store the artifact before the requests.
    KilnCMS.DataCase.drain_oban()

    %{post: post, admin: admin, price: price, colour: colour}
  end

  # Unpublish → edit → publish, the workflow that changes live content; the
  # publish re-fires the artifact.
  defp republish(post, admin, attrs) do
    post = CMS.unpublish_post!(post, %{}, actor: admin)
    post = CMS.update_post!(post, attrs, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    post
  end

  defp fetch(conn, post, query), do: get(conn, "/api/content/post/#{post.slug}?#{query}")

  test "keeps only the named keys, plus id and type", ctx do
    body = ctx.conn |> fetch(ctx.post, "fields=title,slug") |> json_response(200)

    assert body == %{
             "id" => ctx.post.id,
             "type" => "post",
             "title" => "Sparse",
             "slug" => ctx.post.slug
           }
  end

  test "custom_fields.<name> keeps just that custom field", ctx do
    body =
      ctx.conn |> fetch(ctx.post, "fields=title,custom_fields.#{ctx.price}") |> json_response(200)

    assert body["custom_fields"] == %{ctx.price => "12"}
    refute Map.has_key?(body, "blocks")
  end

  test "a bare custom_fields keeps all of them", ctx do
    body =
      ctx.conn
      |> fetch(ctx.post, "fields=custom_fields,custom_fields.#{ctx.price}")
      |> json_response(200)

    assert body["custom_fields"] == %{ctx.price => "12", ctx.colour => "red"}
  end

  test "unknown names are ignored, not refused", ctx do
    body =
      ctx.conn
      |> fetch(ctx.post, "fields=title,nope,custom_fields.nope")
      |> json_response(200)

    assert body == %{
             "id" => ctx.post.id,
             "type" => "post",
             "title" => "Sparse",
             "custom_fields" => %{}
           }
  end

  test "a blank fieldset is the whole artifact", ctx do
    whole = ctx.conn |> fetch(ctx.post, "") |> json_response(200)
    blank = build_conn() |> fetch(ctx.post, "fields=,%20") |> json_response(200)

    assert blank == whole
    assert Map.has_key?(whole, "blocks")
  end

  test "the canonical fieldset is echoed back as x-kiln-fields", ctx do
    conn = fetch(ctx.conn, ctx.post, "fields=title,id,slug,title")
    assert ["slug,title"] = get_resp_header(conn, "x-kiln-fields")
    assert [] = build_conn() |> fetch(ctx.post, "") |> get_resp_header("x-kiln-fields")
  end

  describe "ETag" do
    defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

    test "differs per fieldset and from the whole artifact", ctx do
      whole = ctx.conn |> fetch(ctx.post, "") |> etag()
      title = build_conn() |> fetch(ctx.post, "fields=title") |> etag()
      slug = build_conn() |> fetch(ctx.post, "fields=slug") |> etag()

      assert Enum.uniq([whole, title, slug]) == [whole, title, slug]
    end

    test "is the same for every spelling of one fieldset", ctx do
      a = ctx.conn |> fetch(ctx.post, "fields=title,slug") |> etag()
      b = build_conn() |> fetch(ctx.post, "fields=slug,%20title,title,id") |> etag()

      assert a == b
    end

    test "a fieldset request revalidates to 304 with its own tag", ctx do
      served = fetch(ctx.conn, ctx.post, "fields=title")
      assert json_response(served, 200)
      tag = etag(served)

      revalidated =
        build_conn()
        |> put_req_header("if-none-match", tag)
        |> fetch(ctx.post, "fields=title,title")

      assert revalidated.status == 304
      assert revalidated.resp_body == ""
    end

    test "is computed over the filtered body: it moves only when a kept field does", ctx do
      %{post: post, admin: admin} = ctx
      tag = ctx.conn |> fetch(post, "fields=custom_fields.#{ctx.price}") |> etag()

      # A republish that changed only an unkept field: the document changed, the fieldset's
      # tag did not, and the old one still revalidates.
      post = republish(post, admin, %{custom_fields: %{ctx.price => "12", ctx.colour => "blue"}})

      assert build_conn()
             |> fetch(post, "")
             |> json_response(200)
             |> get_in(["custom_fields", ctx.colour]) ==
               "blue"

      assert build_conn()
             |> put_req_header("if-none-match", tag)
             |> fetch(post, "fields=custom_fields.#{ctx.price}")
             |> Map.fetch!(:status) == 304

      # Change the kept field and the tag moves with it.
      post = republish(post, admin, %{custom_fields: %{ctx.price => "13", ctx.colour => "blue"}})

      changed =
        build_conn()
        |> put_req_header("if-none-match", tag)
        |> fetch(post, "fields=custom_fields.#{ctx.price}")

      assert json_response(changed, 200)["custom_fields"] == %{ctx.price => "13"}
      assert etag(changed) != tag
    end

    test "the whole artifact's tag does not 304 a fieldset, nor the reverse", ctx do
      whole = ctx.conn |> fetch(ctx.post, "") |> etag()
      sparse = build_conn() |> fetch(ctx.post, "fields=title") |> etag()

      assert build_conn()
             |> put_req_header("if-none-match", whole)
             |> fetch(ctx.post, "fields=title")
             |> json_response(200) == %{
               "id" => ctx.post.id,
               "type" => "post",
               "title" => "Sparse"
             }

      assert build_conn()
             |> put_req_header("if-none-match", sparse)
             |> fetch(ctx.post, "")
             |> json_response(200)
             |> Map.has_key?("blocks")
    end
  end

  describe "refusals" do
    test "fields needs surface=json", ctx do
      body =
        ctx.conn |> fetch(ctx.post, "fields=title&surface=json_ld") |> json_response(400)

      assert inspect(body) =~ "invalid_fields"
    end

    test "more than 50 names is a 400", ctx do
      names = Enum.map_join(1..51, ",", &"f#{&1}")
      body = ctx.conn |> fetch(ctx.post, "fields=#{names}") |> json_response(400)
      assert inspect(body) =~ "invalid_fields"
    end

    test "a non-string fields is a 400", ctx do
      body = ctx.conn |> fetch(ctx.post, "fields[]=title") |> json_response(400)
      assert inspect(body) =~ "invalid_fields"
    end
  end

  test "applies to a point-in-time read too", ctx do
    as_of = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

    conn = fetch(ctx.conn, ctx.post, "fields=title&as_of=#{URI.encode_www_form(as_of)}")

    assert json_response(conn, 200) == %{
             "id" => ctx.post.id,
             "type" => "post",
             "title" => "Sparse"
           }

    assert ["title"] = get_resp_header(conn, "x-kiln-fields")
  end

  describe "canonical/1" do
    test "sorts, de-duplicates and drops the always-kept names" do
      assert ArtifactFields.canonical(~w(title id slug title type expanded)) == ~w(slug title)
    end

    test "folds custom_fields.<name> into a bare custom_fields" do
      assert ArtifactFields.canonical(~w(custom_fields.a custom_fields title)) ==
               ~w(custom_fields title)

      assert ArtifactFields.canonical(~w(custom_fields.b custom_fields.a)) ==
               ~w(custom_fields.a custom_fields.b)
    end
  end
end
