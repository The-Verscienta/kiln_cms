defmodule KilnCMSWeb.GovernanceTransitionsTest do
  @moduledoc """
  #1928: the governance trail's "What readers saw" rows. One row per publish
  or withdrawal, with its approver, its propagation record (the CDN purge and
  each webhook endpoint's delivery or terminal failure), its `?as_of=` link
  and the chain's verdict on that version; and the JSON and CSV exports
  carrying the same columns.
  """
  # async: false — sets the global `KilnCMS.CDN` env, and the trail resolves
  # VM-global compliance settings (see `GovernanceLiveTest`).
  use KilnCMSWeb.ConnCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CDN
  alias KilnCMS.CMS

  @password "password123456"

  setup do
    cdn = Application.get_env(:kiln_cms, CDN, [])
    on_exit(fn -> Application.put_env(:kiln_cms, CDN, cdn) end)
    Application.put_env(:kiln_cms, CDN, Keyword.put(cdn, :purge_url, nil))
    :ok
  end

  defp authed_user(role) do
    email = "gov-transitions-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp slug, do: "govt-#{System.unique_integer([:positive])}"

  defp drain,
    do: Oban.drain_queue(queue: :webhooks, with_scheduled: true, with_recursion: true)

  # A post published and then withdrawn by `admin`, with the CDN purge on and
  # two endpoints subscribed: one that answers, one that never does.
  defp published_then_withdrawn!(admin) do
    Application.put_env(
      :kiln_cms,
      CDN,
      Keyword.put(Application.get_env(:kiln_cms, CDN, []), :purge_url, "https://purge.test/p")
    )

    Req.Test.stub(CDN, &Plug.Conn.send_resp(&1, 200, "{}"))

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      Plug.Conn.send_resp(conn, if(conn.host == "dead.test", do: 503, else: 200), "{}")
    end)

    CMS.create_webhook_endpoint!(%{url: "https://good.test/hook"}, actor: admin)
    CMS.create_webhook_endpoint!(%{url: "https://dead.test/hook"}, actor: admin)

    post = CMS.create_post!(%{title: "Dosage Advice", slug: slug()}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)
    drain()
    post = CMS.unpublish_post!(post, %{}, actor: admin)
    drain()
    post
  end

  describe "the detail view" do
    test "each transition is one row with its approver, propagation, as_of link and chain verdict",
         %{conn: conn} do
      admin = authed_user(:admin)
      post = published_then_withdrawn!(admin)

      {:ok, view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")
      assert html =~ "What readers saw"

      # create = 1, publish = 2, unpublish = 3: the rows are keyed by the
      # version's place in the fold order, newest first.
      rows =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#transitions tbody tr")

      assert Enum.map(rows, &LazyHTML.attribute(&1, "id")) == [["transition-3"], ["transition-2"]]

      for row <- ["#transition-2", "#transition-3"] do
        assert has_element?(view, "#{row} [data-role=approver]", to_string(admin.email))
        assert has_element?(view, "#{row} [data-role=cdn]", "acknowledged")
        assert has_element?(view, "#{row} [data-role=cdn]", "enqueued")
        assert has_element?(view, "#{row} [data-role=endpoints]", "https://good.test/hook")
        assert has_element?(view, "#{row} [data-role=endpoints]", "delivered")
        assert has_element?(view, "#{row} [data-role=row-chain]")
      end

      # The endpoint that never answered is a terminal failure, with its error.
      assert has_element?(view, "#transition-3 [data-role=endpoints]", "https://dead.test/hook")
      assert has_element?(view, "#transition-3 [data-role=endpoints]", "given up")
      assert has_element?(view, "#transition-3 [data-role=endpoints]", "503")

      assert has_element?(view, "#transition-2", "publish")
      assert has_element?(view, "#transition-3", "unpublish")

      # The `?as_of=` link, on the withdrawal as well as the publish.
      assert has_element?(
               view,
               ~s(#transition-3 a[href^="/api/content/post/#{post.slug}?as_of="]),
               "View as of then"
             )
    end

    test "a transition that put nothing on the delivery path says it has no record",
         %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Shelved Draft", slug: slug()}, actor: admin)
      CMS.archive_post!(post, %{}, actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert has_element?(view, "#transition-2", "archive")

      assert has_element?(
               view,
               "#transition-2 [data-role=no-propagation]",
               "No propagation record"
             )

      assert has_element?(view, "#transition-2 [data-role=approver]", to_string(admin.email))
    end

    test "a scheduled publish names whoever set the schedule as its approver", %{conn: conn} do
      admin = authed_user(:admin)
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      post =
        CMS.create_post!(%{title: "Scheduled Note", slug: slug(), scheduled_at: at}, actor: admin)

      # The scheduler runs it with no user on the write.
      CMS.publish_scheduled_post!(post, %{}, authorize?: false)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert has_element?(view, "#transition-2", "run by the scheduler")
      assert has_element?(view, "#transition-2 [data-role=approver]", to_string(admin.email))
      # Sent nowhere and nothing to purge: a record, settled at once.
      assert has_element?(view, "#transition-2 [data-role=endpoints]", "No endpoints subscribed")
      assert has_element?(view, "#transition-2 [data-role=cdn]", "not configured")
    end

    test "a document never published or withdrawn has no rows", %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Quiet Draft", slug: slug()}, actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")
      assert has_element?(view, "#transitions", "Never published or withdrawn.")
      refute has_element?(view, "#transitions tbody tr")
    end
  end

  describe "the exports" do
    test "the JSON export carries one transition per row with its propagation", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_then_withdrawn!(admin)

      body =
        conn
        |> log_in(admin)
        |> get(~p"/editor/governance/post/#{post.id}/export.json")
        |> json_response(200)

      assert [withdrawal, publish] = body["transitions"]

      assert %{"action" => "unpublish", "kind" => "withdraw", "scheduled?" => false} = withdrawal
      assert %{"action" => "publish", "kind" => "publish"} = publish

      for transition <- [withdrawal, publish] do
        assert transition["approver"] == to_string(admin.email)
        assert transition["as_of_url"] =~ "/api/content/post/#{post.slug}?as_of="
        assert is_binary(transition["chain"])
        assert transition["propagation_missing"] == nil

        propagation = transition["propagation"]
        assert propagation["cdn"]["status"] == "acknowledged"
        assert propagation["cdn"]["enqueued_at"]
        assert propagation["cdn"]["settled_at"]
        assert propagation["completed_at"]
      end

      assert withdrawal["propagation"]["event"] == "post.unpublished"

      endpoints = Map.new(withdrawal["propagation"]["endpoints"], &{&1["url"], &1})

      assert %{"status" => "succeeded", "delivered_at" => at} =
               endpoints["https://good.test/hook"]

      assert is_binary(at)

      assert %{"status" => "failed", "failed_at" => failed_at, "error" => error} =
               endpoints["https://dead.test/hook"]

      assert is_binary(failed_at)
      assert error =~ "503"
    end

    test "the CSV export carries the same columns", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_then_withdrawn!(admin)

      csv =
        conn
        |> log_in(admin)
        |> get(~p"/editor/governance/post/#{post.id}/export.csv")
        |> response(200)

      [header | lines] = String.split(csv, "\r\n", trim: true)

      assert header ==
               "kind,at,action,who,publish,changed,reference,note," <>
                 "cdn_purge,cdn_enqueued_at,cdn_settled_at,endpoints,as_of,chain"

      columns = String.split(header, ",")
      transitions = Enum.filter(lines, &String.starts_with?(&1, "transition,"))
      assert [withdrawal, publish] = transitions

      assert withdrawal =~ ",unpublish,#{admin.email},false,"
      assert withdrawal =~ "post.unpublished"
      assert withdrawal =~ "settled at "
      assert withdrawal =~ ",acknowledged,"
      assert withdrawal =~ "https://good.test/hook delivered "
      assert withdrawal =~ "https://dead.test/hook failed "
      assert withdrawal =~ "/api/content/post/#{post.slug}?as_of="
      assert publish =~ ",publish,#{admin.email},true,"

      # Every row has every column; the non-transition rows leave the
      # propagation ones empty.
      version = Enum.find(lines, &String.starts_with?(&1, "version,"))
      assert String.ends_with?(version, ",,,,,,")
      assert length(String.split(version, ",")) >= length(columns)
    end
  end
end
