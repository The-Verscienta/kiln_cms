defmodule KilnCMSWeb.ArtifactControllerResilienceTest do
  @moduledoc """
  "Stays up when the database doesn't" — end-to-end delivery resilience (#341).

  The outage is genuine: the request is dispatched from a bare spawned process
  which, in the async (non-shared) sandbox, has no connection allowance, so any
  database access raises exactly as a Postgres outage would. A warm request
  served through that proves delivery never needed the database.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "res-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "res-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Always Up",
          slug: slug,
          blocks: [%{type: :heading, content: "Cached", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    slug
  end

  # Dispatch `fun` from a bare, unallowed process (no sandbox `$callers`): any
  # database access raises, exactly as a Postgres outage would.
  defp without_db(fun) do
    parent = self()
    spawn(fn -> send(parent, {:without_db, fun.()}) end)

    receive do
      {:without_db, result} -> result
    after
      3000 -> flunk("timed out")
    end
  end

  # Warm the caches (resolution + fired body) while the DB is up, then dispatch
  # the same GET from a process with no DB access. The content cache is global
  # and other suites bust it WIDE mid-run (media/form/promotion writes call
  # `Cache.bust_published/0`), so a concurrent async test can wipe our warm
  # entry between warm-up and the outage dispatch — when that race hits (503),
  # re-warm and try again. The property under test — a WARM entry is served
  # without Postgres — is unaffected by the retry.
  defp warm_then_get_without_db(path, retries \\ 3) do
    assert json_response(get(build_conn(), path), 200)

    resp = without_db(fn -> get(build_conn(), path) end)

    if resp.status == 503 and retries > 0 do
      warm_then_get_without_db(path, retries - 1)
    else
      resp
    end
  end

  test "serves warm content through a full database outage" do
    slug = published_page()

    # The warm path never touches Postgres, so delivery keeps answering.
    resp = warm_then_get_without_db(~p"/api/content/page/#{slug}")
    assert json_response(resp, 200)["slug"] == slug
  end

  test "serves every warm surface through an outage" do
    slug = published_page()

    for surface <- ["json", "json_ld", "web"] do
      assert json_response(
               get(build_conn(), ~p"/api/content/page/#{slug}?surface=#{surface}"),
               200
             )
    end

    resp = warm_then_get_without_db(~p"/api/content/page/#{slug}?surface=web")
    assert json_response(resp, 200)["html"] =~ "Cached"
  end

  test "degrades to a retryable 503 for cold content during an outage" do
    cold_slug = "res-cold-#{System.unique_integer([:positive])}"

    resp = without_db(fn -> get(build_conn(), ~p"/api/content/page/#{cold_slug}") end)

    assert %{"errors" => [%{"code" => "temporarily_unavailable", "status" => "503"}]} =
             json_response(resp, 503)

    assert ["2"] = get_resp_header(resp, "retry-after")
  end
end
