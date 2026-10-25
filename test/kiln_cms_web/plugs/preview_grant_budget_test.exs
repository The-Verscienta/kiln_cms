defmodule KilnCMSWeb.Plugs.PreviewGrantBudgetTest do
  @moduledoc """
  The `:preview_api` bucket (#1887): a read that presents a preview token is
  charged to it on top of `:api`, and one over it is refused with a 429. Lowers
  the bucket in the global `RateLimit` env, so `async: false`, and restores it.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.PreviewToken
  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.RateLimit

  setup do
    RateLimitHelpers.restore_limits_on_exit()
  end

  defp draft_post do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "pgb-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.create_post!(%{title: "Budget draft", slug: "pgb-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  test "the bucket exists, sized for a few reviewers behind one front end" do
    assert {limit, scale} = RateLimit.default_limits()[:preview_api]
    assert scale == :timer.minutes(1)
    assert limit >= 60 and limit <= 300
  end

  test "token reads over the bucket are refused; reads without a token are not charged",
       %{conn: conn} do
    RateLimitHelpers.put_limit(:preview_api, 2)
    post = draft_post()
    token = PreviewToken.sign(post)
    {conn, ip} = client_conn(conn)

    read = fn token ->
      conn
      |> recycle()
      |> put_req_header("accept", "application/vnd.api+json")
      |> then(&if(token, do: put_req_header(&1, "x-kiln-preview-token", token), else: &1))
      |> get("/api/json/posts/#{post.id}")
    end

    # Anonymous reads spend nothing on this bucket.
    assert read.(nil).status == 404
    assert RateLimitHelpers.spent(:preview_api, ip) == 0

    assert read.(token).status == 200
    assert read.(token).status == 200
    assert read.(token).status == 429
  end
end
