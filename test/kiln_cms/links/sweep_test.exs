defmodule KilnCMS.Links.SweepTest do
  @moduledoc """
  Scan → queue → check → report, end to end (#474, external half).

  The unit tests either side of this prove that the checker classifies a status
  and that the extractor finds a URL. What only an end-to-end test can show is
  that the URL an author saved is the URL that reaches the network — the trap
  that shipped #489 inert, where `TypedBlocks.sanitize_attrs/1` rewrote the
  stored value on the way in and nothing downstream ever saw it.

  `async: false`: the throttle and the opt-in are application state.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ExternalLink
  alias KilnCMS.Links.CheckWorker
  alias KilnCMS.Links.Settings
  alias KilnCMS.Links.Sweep
  alias KilnCMS.Links.SweepWorker

  @url "https://example.test/cited"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "links-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    org = KilnCMS.Accounts.default_org_id()
    {:ok, _settings} = Settings.save(org, true, actor: admin)

    %{admin: admin, org: org}
  end

  defp respond(status) do
    Req.Test.stub(KilnCMS.Links.External, fn conn ->
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp published_page(url, admin) do
    n = System.unique_integer([:positive])

    page =
      CMS.create_page!(
        %{
          title: "Page #{n}",
          slug: "linkcheck-#{n}",
          blocks: [
            %{
              "_type" => "rich_text",
              "body" => [
                %{
                  "_type" => "block",
                  "style" => "normal",
                  "children" => [%{"text" => "See this"}],
                  "markDefs" => [%{"_type" => "link", "href" => url}]
                }
              ]
            }
          ]
        },
        actor: admin
      )

    CMS.publish_page!(page, actor: admin)
  end

  defp rows(org) do
    ExternalLink
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false, tenant: org)
  end

  defp check_jobs, do: all_enqueued(worker: CheckWorker)

  describe "the scan" do
    test "records the URL an author actually saved", %{admin: admin, org: org} do
      # The #489 lesson: what the write path does to the value in between is
      # exactly what a unit test on either side cannot see.
      page = published_page(@url, admin)
      Sweep.run_org(org)

      assert [row] = rows(org)
      assert row.url == @url
      assert row.host == "example.test"
      assert row.document_type == "page"
      assert row.document_id == page.id
      assert row.document_title == page.title
      assert row.block_index == 0
      assert row.outcome == :pending
    end

    test "a URL in two documents is two rows and one job", %{admin: admin, org: org} do
      published_page(@url, admin)
      published_page(@url, admin)

      Sweep.run_org(org)

      assert length(rows(org)) == 2
      # Forty citations must cost one request, not forty.
      assert [%{args: %{"url" => @url}}] = check_jobs()
    end

    test "drafts are not scanned", %{admin: admin, org: org} do
      n = System.unique_integer([:positive])

      CMS.create_page!(
        %{
          title: "Draft #{n}",
          slug: "draft-#{n}",
          blocks: [%{"_type" => "claim", "text" => "x", "source_url" => @url}]
        },
        actor: admin
      )

      Sweep.run_org(org)

      assert rows(org) == []
    end

    test "a link removed from a document is pruned on the next sweep", %{admin: admin, org: org} do
      page = published_page(@url, admin)
      Sweep.run_org(org)
      assert [_row] = rows(org)

      CMS.update_page!(page, %{blocks: [%{"_type" => "divider"}]}, actor: admin)
      Sweep.run_org(org)

      assert rows(org) == []
    end

    test "an unpublished document's links are pruned too", %{admin: admin, org: org} do
      page = published_page(@url, admin)
      Sweep.run_org(org)
      assert [_row] = rows(org)

      CMS.archive_page!(page, actor: admin)
      Sweep.run_org(org)

      # One rule — "older than this run" — covers removal, unpublishing and
      # deletion, rather than three hooks that each have to remember.
      assert rows(org) == []
    end

    test "a healthy link is not re-queued until its recheck window passes", %{
      admin: admin,
      org: org
    } do
      published_page(@url, admin)
      Sweep.run_org(org)

      respond(200)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})

      Oban.Repo.delete_all(Oban.config(), Oban.Job)
      Sweep.run_org(org)

      assert check_jobs() == []
    end
  end

  describe "the check" do
    setup %{admin: admin, org: org} do
      published_page(@url, admin)
      Sweep.run_org(org)
      :ok
    end

    test "a 404 is written to every occurrence", %{admin: admin, org: org} do
      published_page(@url, admin)
      Sweep.run_org(org)

      respond(404)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})

      assert [a, b] = rows(org)
      assert a.outcome == :broken
      assert b.outcome == :broken
      assert a.status_code == 404
      assert a.failure_count == 1
      refute is_nil(a.first_failed_at)
    end

    test "a 200 is ok, with the counter at zero and no failure date", %{org: org} do
      respond(200)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})

      assert [row] = rows(org)
      assert row.outcome == :ok
      assert row.failure_count == 0
      assert is_nil(row.first_failed_at)
    end

    test "a 5xx is not reported until the third consecutive failure", %{org: org} do
      respond(503)

      for expected <- [:transient, :transient, :broken] do
        assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
        assert [%{outcome: ^expected}] = rows(org)
      end

      # The web has bad minutes. An author hearing about every one of them is an
      # author who stops reading the report.
      assert [%{failure_count: 3, reason: reason}] = rows(org)
      assert reason =~ "consecutive"
    end

    test "a recovery resets the counter", %{org: org} do
      respond(503)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
      assert [%{failure_count: 1}] = rows(org)

      respond(200)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})

      assert [%{outcome: :ok, failure_count: 0, first_failed_at: nil}] = rows(org)
    end

    test "a 403 changes nothing and never escalates", %{org: org} do
      respond(403)

      for _run <- 1..4 do
        assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
      end

      # Four bot-wall responses in a row are still not evidence of a dead link.
      assert [%{outcome: :undetermined, failure_count: 0}] = rows(org)
    end

    test "the throttle snoozes instead of holding the slot", %{org: org} do
      previous = Application.get_env(:kiln_cms, KilnCMS.Links.Throttle, [])
      Application.put_env(:kiln_cms, KilnCMS.Links.Throttle, per_host: {1, 60_000})
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Links.Throttle, previous) end)

      respond(200)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})

      assert {:snooze, seconds} = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
      assert seconds >= 1
    end
  end

  describe "the opt-in" do
    test "a site that has not opted in is not swept", %{admin: admin, org: org} do
      published_page(@url, admin)
      {:ok, _settings} = Settings.save(org, false, actor: admin)

      assert :ok = perform_job(SweepWorker, %{})

      assert rows(org) == []
      assert check_jobs() == []
    end

    test "a queued check is cancelled when checking is switched off", %{admin: admin, org: org} do
      published_page(@url, admin)
      Sweep.run_org(org)

      {:ok, _settings} = Settings.save(org, false, actor: admin)

      # The switch means "this deployment does not make these requests", so the
      # place it has to be honoured is immediately before the request — not only
      # in the sweep that queued this an hour ago.
      assert {:cancel, _reason} = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
      assert [%{outcome: :pending}] = rows(org)
    end

    test "settings default to off for a site that has never saved them" do
      org = Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{name: "Other", slug: "other-lc"})

      refute Settings.enabled?(org.id)
      assert Settings.for_org(org.id) == nil
    end
  end
end
