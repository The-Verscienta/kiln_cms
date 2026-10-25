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

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CDN
  alias KilnCMS.CMS
  alias KilnCMS.Governance

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
      end

      # The publish minted the anchor that covers it (unsigned: no key in the
      # test build); nothing has anchored the withdrawal after it yet.
      assert has_element?(view, "#transition-2 [data-role=row-chain]", "intact (unsigned)")
      assert has_element?(view, "#transition-3 [data-role=row-chain]", "not yet anchored")

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
               "nothing was live to take down"
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

  describe "what the row says when the ledger has moved on" do
    test "endpoints whose deliveries were pruned are counted, with how they fared", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_then_withdrawn!(admin)

      # The ledger keeps 30 days, the records 90: delete what the nightly prune
      # would, which keeps a failed retraction.
      KilnCMS.Repo.delete_all(
        from(d in "webhook_deliveries", where: d.status != "failed" or d.retraction == false)
      )

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      # The publish: both rows gone, one of them a failure.
      refute has_element?(view, "#transition-2 [data-role=endpoints]", "No endpoints subscribed")

      assert has_element?(
               view,
               "#transition-2 [data-role=endpoints-pruned]",
               "Sent to 2 endpoints whose delivery detail was pruned"
             )

      assert has_element?(
               view,
               "#transition-2 [data-role=endpoints-pruned]",
               "1 endpoint given up on"
             )

      # The withdrawal: the kept failed retraction is still listed by name.
      assert has_element?(
               view,
               "#transition-3 [data-role=endpoints-pruned]",
               "Sent to 1 endpoint"
             )

      assert has_element?(view, "#transition-3 [data-role=endpoints]", "https://dead.test/hook")

      csv =
        conn
        |> log_in(admin)
        |> get(~p"/editor/governance/post/#{post.id}/export.csv")
        |> response(200)

      assert csv =~ "2 endpoint(s) pruned from the ledger, 1 given up on"
    end

    test "a transition every endpoint received still says when, once its rows are pruned",
         %{conn: conn} do
      admin = authed_user(:admin)
      Req.Test.stub(KilnCMS.Webhooks, &Plug.Conn.send_resp(&1, 200, "{}"))
      CMS.create_webhook_endpoint!(%{url: "https://good.test/hook"}, actor: admin)

      post = CMS.create_post!(%{title: "Quiet Success", slug: slug()}, actor: admin)
      CMS.publish_post!(post, %{}, actor: admin)
      drain()
      KilnCMS.Repo.delete_all("webhook_deliveries")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert has_element?(
               view,
               "#transition-2 [data-role=endpoints-pruned]",
               "All endpoints delivered by"
             )
    end

    test "a lost retraction later delivered shows when the consumer was told", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_then_withdrawn!(admin)

      lost =
        Enum.find(
          CMS.list_webhook_deliveries!(authorize?: false),
          &(&1.event == "post.unpublished" and &1.status == :failed)
        )

      assert %DateTime{} = gave_up = lost.failed_at

      # The consumer is back; the admin replays the retraction.
      Req.Test.stub(KilnCMS.Webhooks, &Plug.Conn.send_resp(&1, 200, "{}"))
      KilnCMS.Webhooks.redeliver(lost)
      drain()

      recovered = CMS.get_webhook_delivery!(lost.id, authorize?: false)
      assert recovered.recovered_at
      # The recovery stamp moved `updated_at`; the give-up time is its own.
      assert DateTime.compare(recovered.updated_at, gave_up) == :gt
      assert CMS.WebhookDelivery.given_up_at(recovered) == gave_up

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")
      assert has_element?(view, "#transition-3 [data-role=recovered]", "told later")
    end
  end

  describe "transitions the propagation records do not cover" do
    test "restoring a document trashed while live is a row of its own", %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Back Again", slug: slug()}, actor: admin)
      post = CMS.publish_post!(post, %{}, actor: admin)
      CMS.destroy_post!(post, actor: admin)
      [trashed] = CMS.list_trashed_posts!(actor: admin, query: [filter: [id: post.id]])
      CMS.restore_post!(trashed, %{}, actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert has_element?(view, "#transition-3", "destroy")
      assert has_element?(view, "#transition-4", "restore")
      assert has_element?(view, "#transition-4", "back from the trash, live again")
      assert has_element?(view, "#transition-4 [data-role=approver]", to_string(admin.email))

      assert has_element?(
               view,
               "#transition-4 [data-role=no-propagation]",
               "without a propagation record"
             )

      # Point-in-time delivery does not model a restore: no link that would
      # call the document withdrawn while readers could see it.
      refute has_element?(view, "#transition-4 a", "View as of then")
    end

    test "restoring a trashed draft is not a transition", %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Never Live", slug: slug()}, actor: admin)
      CMS.destroy_post!(post, actor: admin)
      [trashed] = CMS.list_trashed_posts!(actor: admin, query: [filter: [id: post.id]])
      CMS.restore_post!(trashed, %{}, actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert has_element?(view, "#transition-2", "destroy")
      refute has_element?(view, "#transition-3")
    end

    test "an embargo end run by the scheduler names whoever set it", %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Embargo", slug: slug()}, actor: admin)
      post = CMS.publish_post!(post, %{}, actor: admin)

      post =
        CMS.update_post!(post, %{unpublish_at: DateTime.add(DateTime.utc_now(), 3600)},
          actor: admin
        )

      CMS.archive_scheduled_post!(post, %{}, authorize?: false)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert has_element?(view, "#transition-4", "archive_scheduled")
      assert has_element?(view, "#transition-4", "run by the scheduler")
      assert has_element?(view, "#transition-4 [data-role=approver]", to_string(admin.email))
      assert has_element?(view, "#transition-4 a", "View as of then")
    end
  end

  describe "the chain verdict on a row" do
    test "a tampered chain vouches for none of its rows", %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Doctored Row", slug: slug()}, actor: admin)
      CMS.publish_post!(post, %{}, actor: admin)

      KilnCMS.Repo.update_all(
        from(v in "posts_versions",
          where: v.version_source_id == type(^post.id, :binary_id),
          update: [set: [changes: type(^%{"title" => "Doctored"}, :map)]]
        ),
        []
      )

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")
      assert has_element?(view, "#transition-2 [data-role=row-chain]", "tampered")
    end

    test "row_verdict/2 tells the attested prefix from what lies past it" do
      head = %{version_count: 7}
      gap = %{verdict: :unsigned, gap: {:gap, 4, 7}, head: head}

      assert Governance.row_verdict(3, gap) == :verified
      assert Governance.row_verdict(4, gap) == :verified
      assert Governance.row_verdict(5, gap) == :unattested
      assert Governance.row_verdict(8, gap) == :unanchored

      assert Governance.row_verdict(2, %{verdict: :unsigned, gap: :none, head: head}) == :unsigned

      assert Governance.row_verdict(2, %{verdict: :unanchored, gap: :none, head: nil}) ==
               :unanchored

      assert Governance.row_verdict(2, %{verdict: {:tampered, "x"}, gap: gap.gap, head: head}) ==
               :tampered
    end

    test "missing_reason/4 never says \"nothing was live\" of a publish" do
      now = DateTime.utc_now()
      recent = %{action: :publish, at: now}
      old = %{action: :publish, at: DateTime.add(now, -91, :day)}

      assert Governance.missing_reason(recent, :publish, false, now) == :unrecorded
      assert Governance.missing_reason(old, :publish, false, now) == :pruned

      assert Governance.missing_reason(%{action: :unpublish, at: now}, :withdraw, true, now) ==
               :unrecorded

      assert Governance.missing_reason(%{action: :archive, at: now}, :withdraw, false, now) ==
               :not_live

      assert Governance.missing_reason(%{action: :restore, at: now}, :publish, false, now) ==
               :not_measured
    end
  end

  describe "WebhookDelivery.given_up_at/1" do
    test "never reads a later write as the give-up time" do
      at = ~U[2026-10-01 10:00:00.000000Z]
      later = ~U[2026-10-02 10:00:00.000000Z]

      row = %{
        status: :failed,
        failed_at: nil,
        recovered_at: nil,
        payload_scrubbed_at: nil,
        updated_at: at
      }

      assert CMS.WebhookDelivery.given_up_at(%{row | failed_at: at, updated_at: later}) == at
      assert CMS.WebhookDelivery.given_up_at(row) == at

      assert CMS.WebhookDelivery.given_up_at(%{row | recovered_at: later, updated_at: later}) ==
               nil

      assert CMS.WebhookDelivery.given_up_at(%{
               row
               | payload_scrubbed_at: later,
                 updated_at: later
             }) ==
               nil

      assert CMS.WebhookDelivery.given_up_at(%{row | status: :succeeded}) == nil
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
