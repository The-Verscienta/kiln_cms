defmodule KilnCMSWeb.Plugs.IdempotencyTest do
  @moduledoc """
  `Idempotency-Key` on the headless writes (`KilnCMSWeb.Plugs.Idempotency`):
  a retried create or transition replays the first response instead of running
  twice.
  """
  use KilnCMSWeb.ConnCase, async: true

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.IdempotentRequest
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "idem-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "idempotency",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "idem-#{System.unique_integer([:positive])}"

  defp req(method, path, key, body, idempotency_key) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn =
      if idempotency_key,
        do: put_req_header(conn, "idempotency-key", idempotency_key),
        else: conn

    dispatch(conn, @endpoint, method, path, Jason.encode!(body))
  end

  defp create_body(title, slug),
    do: %{data: %{type: "page", attributes: %{title: title, slug: slug}}}

  defp pages_titled(title, admin),
    do: CMS.list_pages!(actor: admin, query: [filter: [title: title]])

  setup do
    admin = user(:admin)
    %{admin: admin, key: key(admin)}
  end

  test "a retried create replays the first response and creates once", ctx do
    title = "Once #{System.unique_integer([:positive])}"
    body = create_body(title, slug())

    first = req(:post, "/api/json/pages", ctx.key, body, "create-1")
    assert first.status == 201
    assert get_resp_header(first, "idempotency-replayed") == []

    second = req(:post, "/api/json/pages", ctx.key, body, "create-1")
    assert second.status == 201
    assert get_resp_header(second, "idempotency-replayed") == ["true"]
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "content-type") == get_resp_header(first, "content-type")

    assert [_one] = pages_titled(title, ctx.admin)
  end

  test "without the header, a retry creates twice (nothing changed)", ctx do
    title = "Twice #{System.unique_integer([:positive])}"

    assert req(:post, "/api/json/pages", ctx.key, create_body(title, slug()), nil).status == 201
    assert req(:post, "/api/json/pages", ctx.key, create_body(title, slug()), nil).status == 201

    assert [_, _] = pages_titled(title, ctx.admin)
  end

  test "the same key on a different request is refused with 422", ctx do
    assert req(:post, "/api/json/pages", ctx.key, create_body("A", slug()), "k-2").status == 201

    conn = req(:post, "/api/json/pages", ctx.key, create_body("B", slug()), "k-2")
    assert conn.status == 422
    assert [%{"code" => "idempotency_key_reused"}] = Jason.decode!(conn.resp_body)["errors"]
  end

  test "the fingerprint ignores key order in the body", ctx do
    s = slug()
    title = "Order #{System.unique_integer([:positive])}"
    body_a = ~s({"data":{"type":"page","attributes":{"title":"#{title}","slug":"#{s}"}}})
    body_b = ~s({"data":{"attributes":{"slug":"#{s}","title":"#{title}"},"type":"page"}})

    send_raw = fn raw ->
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{ctx.key}")
      |> put_req_header("idempotency-key", "order-1")
      |> dispatch(@endpoint, :post, "/api/json/pages", raw)
    end

    assert send_raw.(body_a).status == 201
    replay = send_raw.(body_b)
    assert get_resp_header(replay, "idempotency-replayed") == ["true"]
    assert [_one] = pages_titled(title, ctx.admin)
  end

  test "keys are per actor: another user's identical key runs for real", ctx do
    other_admin = user(:admin)
    other_key = key(other_admin)
    title = "Per actor #{System.unique_integer([:positive])}"

    assert req(:post, "/api/json/pages", ctx.key, create_body(title, slug()), "shared").status ==
             201

    conn = req(:post, "/api/json/pages", other_key, create_body(title, slug()), "shared")
    assert conn.status == 201
    assert get_resp_header(conn, "idempotency-replayed") == []
    assert [_, _] = pages_titled(title, ctx.admin)
  end

  test "a retried publish replays instead of failing on the second transition", ctx do
    page = CMS.create_page!(%{title: "Pub", slug: slug()}, actor: ctx.admin)
    body = %{data: %{type: "page", id: page.id, attributes: %{}}}
    path = "/api/json/pages/#{page.id}/publish"

    first = req(:patch, path, ctx.key, body, "publish-1")
    assert first.status == 200

    # Without the key this retry is a 409 (already published); with it, the
    # client gets the answer it missed.
    second = req(:patch, path, ctx.key, body, "publish-1")
    assert second.status == 200
    assert get_resp_header(second, "idempotency-replayed") == ["true"]
    assert req(:patch, path, ctx.key, body, nil).status == 409
  end

  test "a request still in flight answers 409; an abandoned one is taken over", ctx do
    title = "Busy #{System.unique_integer([:positive])}"
    body = create_body(title, slug())
    assert req(:post, "/api/json/pages", ctx.key, body, "busy").status == 201

    [record] =
      IdempotentRequest
      |> Ash.Query.filter(key == "busy")
      |> Ash.read!(authorize?: false)

    # As if the first request were still running.
    record = Ash.Seed.update!(record, %{status: :in_progress, updated_at: DateTime.utc_now()})

    conn = req(:post, "/api/json/pages", ctx.key, body, "busy")
    assert conn.status == 409
    assert get_resp_header(conn, "retry-after") == ["1"]

    assert [%{"code" => "idempotency_request_in_progress"}] =
             Jason.decode!(conn.resp_body)["errors"]

    # As if it had died before it could answer: a retry runs for real. (Here
    # the first attempt did land, so the re-run trips the slug check — the
    # documented cost of a claim whose request crashed.)
    Ash.Seed.update!(record, %{updated_at: DateTime.add(DateTime.utc_now(), -120, :second)})
    conn = req(:post, "/api/json/pages", ctx.key, body, "busy")
    refute conn.status == 409
    assert get_resp_header(conn, "idempotency-replayed") == []
  end

  test "a refused request is not kept, so fixing the credential and retrying works", ctx do
    viewer = user(:viewer)
    viewer_key = key(viewer)
    title = "Forbidden #{System.unique_integer([:positive])}"
    body = create_body(title, slug())

    assert req(:post, "/api/json/pages", viewer_key, body, "fixable").status == 403

    refute IdempotentRequest
           |> Ash.Query.filter(key == "fixable")
           |> Ash.read!(authorize?: false)
           |> Enum.any?()
  end

  test "an invalid key is a 400", ctx do
    conn = req(:post, "/api/json/pages", ctx.key, create_body("X", slug()), "has space")
    assert conn.status == 400
    assert [%{"code" => "idempotency_key_invalid"}] = Jason.decode!(conn.resp_body)["errors"]
  end

  # Two keys on one request: picking either would make the guarantee depend on
  # header order.
  test "two Idempotency-Key headers are a 400", ctx do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{ctx.key}")
      |> Plug.Conn.put_req_header("idempotency-key", "one")
      |> Plug.Conn.prepend_req_headers([{"idempotency-key", "two"}])
      |> dispatch(@endpoint, :post, "/api/json/pages", Jason.encode!(create_body("Y", slug())))

    assert conn.status == 400
  end

  test "GraphQL mutations honour it too", ctx do
    title = "GQL #{System.unique_integer([:positive])}"

    payload =
      Jason.encode!(%{
        query: """
        mutation ($input: CreatePageInput!) {
          createPage(input: $input) { result { id } errors { message } }
        }
        """,
        variables: %{input: %{title: title, slug: slug()}}
      })

    send_gql = fn ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{ctx.key}")
      |> put_req_header("idempotency-key", "gql-1")
      |> post("/gql", payload)
    end

    first = send_gql.()
    second = send_gql.()

    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "idempotency-replayed") == ["true"]
    assert [_one] = pages_titled(title, ctx.admin)
  end
end
