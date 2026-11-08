defmodule KilnCMSWeb.ScannerGuardDeliveryTest do
  @moduledoc """
  The scanner guard on the real delivery path (#2253): HTML 404s feed it,
  redirect-managed misses do not, and a blocked address is refused afterwards.

  `async: false`: the guard's settings are application env and the rule cache is
  one named Cachex instance.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Security.IpBlocklist

  @moduletag :capture_log

  @ip {203, 0, 113, 77}

  setup do
    Application.put_env(:kiln_cms, :scanner_blocking, enabled: true, threshold: 3)
    IpBlocklist.clear()

    on_exit(fn ->
      Application.delete_env(:kiln_cms, :scanner_blocking)
      IpBlocklist.clear()
    end)

    {:ok, conn: %{loopback_conn() | remote_ip: @ip}}
  end

  defp counter_rows do
    %{rows: [[n]]} =
      KilnCMS.Repo.query!("SELECT count(*) FROM throttle_counters WHERE bucket LIKE 'scanner_%'")

    n
  end

  defp rule_count do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "sgd-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    length(CMS.list_ip_block_rules!(actor: admin, tenant: KilnCMS.Accounts.default_org_id()))
  end

  test "repeated 404s render as usual, then the address is refused", %{conn: conn} do
    for n <- 1..4 do
      assert conn |> get("/no-such-page-#{n}") |> response(404)
    end

    assert rule_count() == 1
    assert conn |> get("/no-such-page-5") |> response(403) == ""
  end

  test "a browser navigation is never counted", %{conn: conn} do
    conn = put_req_header(conn, "sec-fetch-mode", "navigate")

    for n <- 1..6, do: assert(conn |> get("/no-such-page-#{n}") |> response(404))

    assert counter_rows() == 0
    assert rule_count() == 0
  end

  test "a redirect-managed path is not a miss", %{conn: conn} do
    page = Ash.Seed.seed!(KilnCMS.CMS.Page, %{title: "T", slug: "sgd-t", state: :published})

    CMS.create_redirect!(
      %{path: "/sgd-old", locale: "en", target_type: "page", target_id: page.id},
      # authorize?: false — test fixture standing in for an editor's rename redirect
      authorize?: false,
      tenant: KilnCMS.Accounts.default_org_id()
    )

    for _ <- 1..6, do: assert(conn |> get("/sgd-old") |> response(301))

    assert counter_rows() == 0
  end

  test "off by default: the same 404s write nothing", %{conn: conn} do
    Application.delete_env(:kiln_cms, :scanner_blocking)

    for n <- 1..6, do: assert(conn |> get("/no-such-page-#{n}") |> response(404))

    assert counter_rows() == 0
  end
end
