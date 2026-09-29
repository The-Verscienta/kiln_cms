defmodule KilnCMS.Links.SystemActorAuthorizationTest do
  @moduledoc """
  What the link checker's own bookkeeping is *authorized* to do, now that the
  sweep, the check worker and the settings reader run as `Links.system/0`
  instead of `authorize?: false` (#1659), and that the reads backing a
  decision fail CLOSED when that grant is gone.

  Every grant has a refusal next to it: the system writes the occurrence rows
  and reads the switch, but cannot flip the switch through the settings form;
  a person who is not an editor reads nothing, and an editor writes nothing.

  Reads assert on the ROW, never on `{:ok, _}`: a refused read under a filter
  policy comes back `{:ok, []}` (or `nil`), so a shape-only assertion would
  pass with the grant removed. The fail-closed tests assert on what a filtered
  read could NOT produce — a raise, or the warning the error path logs.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ExternalLink
  alias KilnCMS.CMS.SiteLinkCheck
  alias KilnCMS.Links
  alias KilnCMS.Links.CheckWorker
  alias KilnCMS.Links.Report
  alias KilnCMS.Links.Settings
  alias KilnCMS.Links.Sweep
  alias KilnCMS.SystemActor

  @url "https://example.test/cited"

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Links.system()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    admin = user(:admin)
    org = KilnCMS.Accounts.default_org_id()
    {:ok, _settings} = Settings.save(org, true, actor: admin)
    %{admin: admin, org: org}
  end

  defp attrs(url \\ @url) do
    %{
      url: url,
      block_index: 0,
      document_type: "page",
      document_id: Ash.UUID.generate(),
      document_title: "Cites it"
    }
  end

  # The raw table, read around every policy: what is actually stored.
  defp stored(org), do: Ash.read!(ExternalLink, authorize?: false, tenant: org)

  defp seeded_row!(org, fields \\ %{}) do
    row = CMS.observe_external_link!(attrs(), authorize?: false, tenant: org)

    if fields == %{} do
      row
    else
      row
      |> Ash.Changeset.for_update(:record_check, fields, authorize?: false, tenant: org)
      |> Ash.update!()
    end
  end

  defp respond(status) do
    Req.Test.stub(KilnCMS.Links.External, fn conn -> Plug.Conn.send_resp(conn, status, "") end)
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  test "Links.system/0 is a system actor labelled :links" do
    assert %SystemActor{subsystem: :links} = Links.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Links.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :links} = Links.system()
    assert Links.with_actor(nil, &Links.system/0) == nil
  end

  describe "ExternalLink — the sweep's and the check's rows" do
    test "the system observes, reads, records a verdict on and prunes a row", %{org: org} do
      assert {:ok, row} = CMS.observe_external_link(attrs(), actor: system(), tenant: org)
      assert row.id in ids(stored(org))

      assert row.id in ids(CMS.list_external_links!(actor: system(), tenant: org))

      assert %Ash.BulkResult{status: :success} =
               ExternalLink
               |> Ash.bulk_update(:record_check, %{outcome: :broken, failure_count: 1},
                 actor: system(),
                 tenant: org,
                 strategy: [:stream],
                 allow_stream_with: :full_read,
                 return_errors?: true
               )

      assert [%{outcome: :broken, failure_count: 1}] = stored(org)

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_destroy(ExternalLink, :destroy, %{},
                 actor: system(),
                 tenant: org,
                 strategy: [:atomic, :stream],
                 return_errors?: true
               )

      assert stored(org) == []
    end

    test "nobody else gets the grant: no actor reads nothing and writes nothing", %{org: org} do
      row = seeded_row!(org)

      refute row.id in ids(CMS.list_external_links!(tenant: org))

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.observe_external_link(attrs("https://example.test/other"), tenant: org)

      assert {:error, %Ash.Error.Forbidden{}} =
               row
               |> Ash.Changeset.for_update(:record_check, %{outcome: :ok}, tenant: org)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(row, tenant: org)
    end

    test "an editor reads the report's rows but writes none of them", %{org: org} do
      editor = user(:editor)
      row = seeded_row!(org)

      assert row.id in ids(CMS.list_external_links!(actor: editor, tenant: org))

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.observe_external_link(attrs("https://example.test/other"),
                 actor: editor,
                 tenant: org
               )

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(row, actor: editor, tenant: org)
    end
  end

  describe "SiteLinkCheck — the switch" do
    test "the system reads the switch and stamps the sweep", %{org: org} do
      assert %SiteLinkCheck{external_enabled: true, last_swept_at: nil} = Settings.for_org(org)

      assert :ok = Settings.record_sweep(org)
      assert %SiteLinkCheck{last_swept_at: %DateTime{}} = Settings.for_org(org)
    end

    test "the system cannot flip the switch or remove it", %{org: org} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_link_check(%{external_enabled: false},
                 actor: system(),
                 tenant: org
               )

      settings = Settings.for_org(org)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(settings, actor: system(), tenant: org)

      assert Settings.enabled?(org)
    end

    test "no actor reads the switch", %{org: org} do
      assert [] == CMS.list_site_link_check!(tenant: org)
    end
  end

  describe "fail closed: a lost grant never reads as a permissive answer" do
    test "the switch reads as off, and says why", %{org: org} do
      log =
        capture_log(fn ->
          assert Links.with_actor(nil, fn -> Settings.for_org(org) end) == nil
        end)

      assert log =~ "could not read settings"
      refute Links.with_actor(nil, fn -> Settings.enabled?(org) end)
    end

    test "a queued check is cancelled before any request goes out", %{org: org} do
      Req.Test.stub(KilnCMS.Links.External, fn _conn -> flunk("no request may go out") end)

      capture_log(fn ->
        assert {:cancel, _reason} =
                 Links.with_actor(nil, fn ->
                   perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
                 end)
      end)
    end

    test "a refused failure-count read writes no verdict, rather than restarting the run",
         %{org: org} do
      seeded_row!(org, %{outcome: :transient, failure_count: 2})

      # The grant disappears while the request is in flight: the switch was
      # readable, the counter is not. A refused read that filtered to "no rows"
      # would log nothing; one read as zero would write `:transient, 1`.
      Req.Test.stub(KilnCMS.Links.External, fn conn ->
        SystemActor.put_override(:links, nil)
        Plug.Conn.send_resp(conn, 503, "")
      end)

      log =
        capture_log(fn ->
          try do
            assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
          after
            SystemActor.delete_override(:links)
          end
        end)

      assert log =~ "could not read the failure count"
      assert [%{outcome: :transient, failure_count: 2}] = stored(org)

      # And with the grant back, the same 503 is the third in a row.
      respond(503)
      assert :ok = perform_job(CheckWorker, %{"org_id" => org, "url" => @url})
      assert [%{outcome: :broken, failure_count: 3}] = stored(org)
    end

    test "a sweep that may not read the due list raises instead of queueing nothing",
         %{org: org} do
      # No published documents, so nothing is observed; one row is due.
      seeded_row!(org)

      capture_log(fn ->
        assert_raise Ash.Error.Forbidden, fn ->
          Links.with_actor(nil, fn -> Sweep.run_org(org) end)
        end
      end)

      assert all_enqueued(worker: CheckWorker) == []
      assert [_row] = stored(org)
    end

    test "a sweep whose observe is refused aborts before its prune", %{admin: admin, org: org} do
      page =
        CMS.create_page!(
          %{
            title: "Cites #{uniq()}",
            slug: "lsa-#{uniq()}",
            blocks: [%{"_type" => "claim", "text" => "x", "source_url" => @url}]
          },
          actor: admin
        )

      CMS.publish_page!(page, actor: admin)
      Sweep.run_org(org)
      assert [%{url: @url}] = stored(org)

      # An editor may read the rows but not write them — a grant that lost
      # `:observe` alone. Skipping the refusal as "one malformed URL" would
      # leave every row un-refreshed for the prune to delete.
      assert_raise Ash.Error.Forbidden, fn ->
        Links.with_actor(user(:editor), fn -> Sweep.run_org(org) end)
      end

      assert [%{url: @url}] = stored(org)
    end
  end

  describe "the report reads as the viewer" do
    test "an editor sees the broken link", %{org: org} do
      seeded_row!(org, %{outcome: :broken, status_code: 404, failure_count: 1})

      assert %{broken: [%{url: @url}], counts: %{broken: 1}} =
               Report.for_org(org, user(:editor))
    end

    test "a viewer the policy refuses gets an error, not a clean report", %{org: org} do
      seeded_row!(org, %{outcome: :broken, status_code: 404, failure_count: 1})

      assert_raise Ash.Error.Forbidden, fn -> Report.for_org(org, nil) end
      assert_raise Ash.Error.Forbidden, fn -> Report.for_org(org, user(:viewer)) end
    end
  end
end
