defmodule KilnCMS.CDNTest do
  @moduledoc """
  The optional CDN purge (`KILN_CDN_PURGE_URL`): an editorial event that changes
  delivery enqueues one purge of the site's surrogate key, and the worker
  `POST`s it in both the Cloudflare (`{"tags": …}`) and Fastly
  (`Surrogate-Key`) shapes.
  """
  # async: false — sets the global `KilnCMS.CDN` app env.
  use KilnCMS.DataCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CDN
  alias KilnCMS.CDN.PurgeWorker
  alias KilnCMS.CMS

  @url "https://purge.example.test/zones/z/purge_cache"

  setup do
    original = Application.get_env(:kiln_cms, CDN, [])
    on_exit(fn -> Application.put_env(:kiln_cms, CDN, original) end)
    :ok
  end

  defp configure(overrides) do
    Application.put_env(
      :kiln_cms,
      CDN,
      Keyword.merge(Application.get_env(:kiln_cms, CDN, []), overrides)
    )
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cdn-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  describe "handle_event/3" do
    test "does nothing while no purge URL is configured" do
      configure(purge_url: nil)

      assert CDN.handle_event("post.published", %{}, org_id()) == :ok
      refute_enqueued(worker: PurgeWorker)
    end

    test "enqueues one scheduled purge per site for events that change delivery" do
      configure(purge_url: @url)

      for event <- ~w(post.published post.unpublished page.updated release.published) do
        assert CDN.handle_event(event, %{}, org_id()) == :ok
      end

      # Four events inside the coalescing window are one purge.
      assert [%{args: %{"org_id" => id, "txn" => nil}, state: "scheduled"}] =
               all_enqueued(worker: PurgeWorker)

      assert id == org_id()
    end

    # A release publishes inside one long transaction. A purge scheduled by an
    # ordinary publish just before it must not absorb the release's dispatches:
    # it would run before the release commits and nothing would purge after.
    test "dispatches inside a transaction coalesce with each other, not with a committed purge" do
      configure(purge_url: @url)

      CDN.handle_event("post.published", %{}, org_id())

      KilnCMS.Repo.transaction(fn ->
        CDN.handle_event("post.published", %{}, org_id())
        CDN.handle_event("release.published", %{}, org_id())
      end)

      assert [_, _] = jobs = all_enqueued(worker: PurgeWorker)
      assert jobs |> Enum.map(& &1.args["txn"]) |> Enum.count(&is_nil/1) == 1
    end

    test "ignores events that change nothing anonymous callers see" do
      configure(purge_url: @url)

      for event <- ~w(post.in_review post.returned_to_draft form.submitted task.assigned ping) do
        CDN.handle_event(event, %{}, org_id())
      end

      refute_enqueued(worker: PurgeWorker)
    end

    test "publishing through the webhook funnel enqueues the purge" do
      configure(purge_url: @url)
      actor = admin()

      post =
        CMS.create_post!(%{title: "Purge me", slug: "cdn-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      refute_enqueued(worker: PurgeWorker)

      CMS.publish_post!(post, %{}, actor: actor)
      assert_enqueued(worker: PurgeWorker, args: %{org_id: post.org_id})
    end
  end

  describe "PurgeWorker" do
    test "POSTs the site's key — never the deployment-wide one — with the token" do
      configure(purge_url: @url, purge_token: "secret")
      test_pid = self()

      Req.Test.stub(CDN, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:purge, conn, body})
        Plug.Conn.send_resp(conn, 200, ~s({"success": true}))
      end)

      assert :ok = perform_job(PurgeWorker, %{org_id: org_id()})

      assert_received {:purge, conn, body}
      key = "kiln-org-#{org_id()}"
      assert conn.method == "POST"
      assert Jason.decode!(body) == %{"tags" => [key]}
      assert Plug.Conn.get_req_header(conn, "surrogate-key") == [key]
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
    end

    test "a named token header carries the bare token (Fastly-Key)" do
      configure(purge_url: @url, purge_token: "fk", purge_token_header: "Fastly-Key")

      assert {"fastly-key", "fk"} in CDN.purge_headers(["k"])
      refute List.keymember?(CDN.purge_headers(["k"]), "authorization", 0)
    end

    test "a non-2xx fails the job so Oban retries it" do
      configure(purge_url: @url)
      Req.Test.stub(CDN, &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, "purge endpoint returned HTTP 503"} =
               perform_job(PurgeWorker, %{org_id: org_id()})
    end

    test "a URL unset between enqueue and run is a no-op" do
      configure(purge_url: nil)

      assert :ok = perform_job(PurgeWorker, %{org_id: org_id()})
    end
  end
end
