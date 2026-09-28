defmodule KilnCMS.DeprecationsTest do
  @moduledoc """
  What 0.12 deprecated (#1538) is gone at 1.0 (#1543), and what outlived it is
  handled: a `use` option that no longer exists warns as unknown, a membership-
  less account's `User.audiences` grants nothing until the post-deploy safety
  net moves it onto a membership, and a job still queued in a pre-0.12 shape is
  cancelled with a logged error instead of running or crash-looping.

  The removed editor route aliases are covered in `KilnCMSWeb.EditorLiveTest`.
  """
  # async: false — `Oban.Job` rows are shared.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo
  # The tests that care capture the log themselves; the rest is noise.
  @moduletag :capture_log

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.LegacyAudiencesWorker
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Deprecations

  @gated hd(Audiences.gated())

  defp default_org_id, do: Accounts.default_org_id()

  defp user(attrs) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "dep-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp admin, do: user(%{role: :admin})

  defp gated_page do
    actor = admin()

    page =
      CMS.create_page!(
        %{title: "Gated", slug: "gated-#{System.unique_integer([:positive])}", audience: @gated},
        actor: actor,
        tenant: default_org_id()
      )

    CMS.publish_page!(page, %{}, actor: actor, tenant: default_org_id())
  end

  defp can_read?(actor, page) do
    CMS.Page
    |> Ash.Query.filter(id == ^page.id)
    |> Ash.read!(actor: actor, tenant: default_org_id())
    |> Enum.any?()
  end

  defp compile_stderr(source, file) do
    capture_io(:stderr, fn ->
      # The warning is raised while the macro expands; whether the rest of a
      # throwaway resource compiles is beside the point here.
      try do
        Code.compile_string(source, file)
      rescue
        _ -> :ok
      end
    end)
  end

  describe "use KilnCMS.CMS.Content options" do
    test "published?: is gone — it now warns as an unknown option, not a deprecation" do
      module = :"Elixir.KilnCMS.CMS.RemovedPublishedOpt#{System.unique_integer([:positive])}"

      stderr =
        compile_stderr(
          """
          defmodule #{inspect(module)} do
            use KilnCMS.CMS.Content,
              type: :page,
              table: "pages",
              published?: true
          end
          """,
          "test/removed_published_opt.exs"
        )

      refute :published? in KilnCMS.CMS.Content.use_options()
      assert stderr =~ "unknown option(s) [:published?] to `use KilnCMS.CMS.Content` are ignored"
      assert stderr =~ "2.0 makes an unknown option a compile error"
      assert stderr =~ "test/removed_published_opt.exs:2"
      refute stderr =~ "is deprecated"
    end

    test "an unknown option warns, naming it" do
      module = :"Elixir.KilnCMS.CMS.UnknownContentOpt#{System.unique_integer([:positive])}"

      stderr =
        compile_stderr(
          """
          defmodule #{inspect(module)} do
            use KilnCMS.CMS.Content,
              type: :page,
              table: "pages",
              exerpt?: true
          end
          """,
          "test/unknown_content_opt.exs"
        )

      assert stderr =~ "unknown option(s) [:exerpt?] to `use KilnCMS.CMS.Content` are ignored"
      assert stderr =~ "test/unknown_content_opt.exs:2"
    end

    test "the accepted set is exactly the options the macro reads" do
      # `use_options/0` is kept by hand beside `__using__/1`; a new option read
      # there but not listed would warn on every overlay that passes it.
      source = File.read!("lib/kiln_cms/cms/content.ex")

      read =
        ~r/Keyword\.(?:get|fetch!|has_key\?)\(opts, :(\w+\??)|opts \|> Keyword\.get\(:(\w+\??)\)/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new(&String.to_existing_atom/1)

      assert read == MapSet.new(KilnCMS.CMS.Content.use_options())
    end
  end

  describe "the removed User.audiences fallback" do
    test "a membership-less account's audiences grant nothing, and nothing is logged" do
      reader = user(%{audiences: [@gated]})
      page = gated_page()

      log = capture_log(fn -> refute can_read?(reader, page) end)
      refute log =~ "User.audiences"
    end

    test "a member reads through the membership" do
      reader = user(%{audiences: []})

      Ash.Seed.seed!(OrgMembership, %{
        organization_id: default_org_id(),
        user_id: reader.id,
        role: :viewer,
        audiences: [@gated]
      })

      assert can_read?(reader, gated_page())
    end
  end

  describe "the post-deploy safety net (LegacyAudiencesWorker)" do
    test "moves an unaffiliated account onto a membership, restoring its access" do
      # A viewer: an editor's tier would read the gated page with or without
      # audiences.
      legacy = user(%{audiences: [@gated], role: :viewer})
      _no_audiences = user(%{audiences: []})
      page = gated_page()

      # After the upgrade and before the job: fail-closed, never wider.
      refute can_read?(legacy, page)

      log = capture_log(fn -> assert :ok = perform_job(LegacyAudiencesWorker, %{}) end)
      assert log =~ "Moved 1 account(s) off the User.audiences fallback"

      membership = Accounts.get_org_membership!(legacy.id, default_org_id(), authorize?: false)
      assert membership.audiences == [@gated]
      assert membership.role == :viewer

      # A fresh process: `Scoping` memoizes affiliation per process.
      assert Task.async(fn -> can_read?(legacy, page) end) |> Task.await()
      assert Deprecations.report().legacy_audience_accounts == []
    end

    test "carries a live temporary role, with its expiry" do
      expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      legacy =
        user(%{
          audiences: [@gated],
          role: :viewer,
          granted_role: :editor,
          granted_role_expires_at: expires
        })

      assert :ok = perform_job(LegacyAudiencesWorker, %{})

      membership = Accounts.get_org_membership!(legacy.id, default_org_id(), authorize?: false)
      assert membership.role == :viewer
      assert membership.granted_role == :editor
      assert DateTime.compare(membership.granted_role_expires_at, expires) == :eq
    end

    test "is a no-op with nothing to migrate, and on a rerun" do
      user(%{audiences: [@gated]})
      assert :ok = perform_job(LegacyAudiencesWorker, %{})

      log = capture_log(fn -> assert :ok = perform_job(LegacyAudiencesWorker, %{}) end)
      refute log =~ "Moved"
    end

    test "never touches an account that already holds a membership" do
      member = user(%{audiences: [@gated]})

      Ash.Seed.seed!(OrgMembership, %{
        organization_id: default_org_id(),
        user_id: member.id,
        role: :viewer,
        audiences: []
      })

      assert :ok = perform_job(LegacyAudiencesWorker, %{})

      assert Accounts.get_org_membership!(member.id, default_org_id(), authorize?: false).audiences ==
               []
    end

    test "enqueue/0 queues one job however many nodes boot" do
      assert :ok = LegacyAudiencesWorker.enqueue()
      assert :ok = LegacyAudiencesWorker.enqueue()

      assert [_one] =
               Oban.Job
               |> Ecto.Query.where(worker: "KilnCMS.Accounts.LegacyAudiencesWorker")
               |> KilnCMS.Repo.all()
    end

    test "the boot enqueue is off in :test only" do
      # Application boot happens OUTSIDE the sandbox; see the occurrence
      # backfill's identical gate in `KilnCMS.Events.BackfillWorkerTest`.
      refute Application.get_env(:kiln_cms, :legacy_audiences_migration_on_boot, true)
    end
  end

  describe "report/0 and run_and_report/2 (mix kiln.deprecations)" do
    test "lists exactly the accounts still on the fallback" do
      legacy = user(%{audiences: [@gated], role: :editor})
      member = user(%{audiences: [@gated]})

      Ash.Seed.seed!(OrgMembership, %{
        organization_id: default_org_id(),
        user_id: member.id,
        role: :viewer,
        audiences: []
      })

      ids = Enum.map(Deprecations.report().legacy_audience_accounts, & &1.id)
      assert ids == [legacy.id]

      assert %{migrated: [migrated], failed: []} = Deprecations.migrate_legacy_audiences()
      assert migrated.id == legacy.id
    end

    test "the report action shows a non-admin nothing" do
      editor = user(%{role: :editor, audiences: [@gated]})
      _legacy = user(%{audiences: [@gated]})

      assert {:ok, []} = Accounts.list_legacy_audience_accounts(actor: editor)
    end

    test "lists queued jobs without org_id, and nothing else" do
      legacy =
        %{"newsletter_send_id" => Ash.UUID.generate()}
        |> KilnCMS.Newsletter.SendWorker.new()
        |> Oban.insert!()

      current =
        %{"newsletter_send_id" => Ash.UUID.generate(), "org_id" => default_org_id()}
        |> KilnCMS.Newsletter.SendWorker.new()
        |> Oban.insert!()

      pre_ledger =
        %{"endpoint_id" => Ash.UUID.generate(), "event" => "page.published", "payload" => %{}}
        |> KilnCMS.Webhooks.DeliveryWorker.new()
        |> Oban.insert!()

      ids = Enum.map(Deprecations.report().legacy_jobs, & &1.id)
      assert legacy.id in ids
      assert pre_ledger.id in ids
      refute current.id in ids
    end

    test "is :ok on a clean instance, and an error listing what is left otherwise" do
      assert :ok = Deprecations.run_and_report([], fn _ -> :ok end)

      legacy = user(%{audiences: [@gated]})
      {:ok, lines} = Agent.start_link(fn -> [] end)
      shell = fn line -> Agent.update(lines, &[line | &1]) end

      assert {:error, _} = Deprecations.run_and_report([], shell)
      printed = lines |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("\n")
      assert printed =~ "Accounts on the removed User.audiences fallback: 1"
      assert printed =~ to_string(legacy.email)

      assert :ok = Deprecations.run_and_report([migrate_audiences: true], shell)
    end
  end

  describe "pre-0.12 Oban job argument shapes are cancelled, loudly" do
    test "a newsletter send job without org_id does not fan out" do
      send =
        Ash.Seed.seed!(KilnCMS.Newsletter.NewsletterSend, %{
          org_id: default_org_id(),
          content_type: "post",
          content_id: Ash.UUID.generate(),
          subject: "Legacy campaign",
          status: :pending
        })

      log =
        capture_log(fn ->
          assert {:cancel, "legacy job arguments" <> _} =
                   KilnCMS.Newsletter.SendWorker.perform(%Oban.Job{
                     args: %{"newsletter_send_id" => send.id}
                   })
        end)

      assert log =~ "[error]"
      assert log =~ "A KilnCMS.Newsletter.SendWorker job was cancelled"
      assert log =~ ~s(keys ["newsletter_send_id"])
      assert log =~ "Drain the queue before upgrading"

      assert KilnCMS.Newsletter.get_send!(send.id, authorize?: false, tenant: default_org_id()).status ==
               :pending
    end

    test "a newsletter mail job without org_id is cancelled without logging the ids" do
      subscriber_id = Ash.UUID.generate()

      log =
        capture_log(fn ->
          assert {:cancel, "legacy job arguments" <> _} =
                   KilnCMS.Newsletter.MailWorker.perform(%Oban.Job{
                     args: %{
                       "newsletter_send_id" => Ash.UUID.generate(),
                       "subscriber_id" => subscriber_id
                     }
                   })
        end)

      assert log =~ "A KilnCMS.Newsletter.MailWorker job was cancelled"
      refute log =~ subscriber_id
    end

    test "a webhook delivery job without org_id is not delivered" do
      test_pid = self()

      Req.Test.stub(KilnCMS.Webhooks, fn conn ->
        send(test_pid, :delivered)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())

      delivery =
        CMS.create_webhook_delivery!(
          %{endpoint_id: endpoint.id, event: "page.published", payload: %{}},
          authorize?: false
        )

      log =
        capture_log(fn ->
          assert {:cancel, _} =
                   KilnCMS.Webhooks.DeliveryWorker.perform(%Oban.Job{
                     args: %{"delivery_id" => delivery.id},
                     attempt: 1,
                     max_attempts: 5
                   })
        end)

      assert log =~ "A KilnCMS.Webhooks.DeliveryWorker job was cancelled"
      refute_received :delivered
    end

    test "a pre-ledger webhook job is not delivered" do
      test_pid = self()

      Req.Test.stub(KilnCMS.Webhooks, fn conn ->
        send(test_pid, :delivered)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())

      log =
        capture_log(fn ->
          assert {:cancel, _} =
                   KilnCMS.Webhooks.DeliveryWorker.perform(%Oban.Job{
                     args: %{
                       "endpoint_id" => endpoint.id,
                       "event" => "page.published",
                       "payload" => %{}
                     }
                   })
        end)

      refute_received :delivered
      assert log =~ ~s(keys ["endpoint_id", "event", "payload"])
    end

    test "run through Oban, the job ends cancelled rather than retrying" do
      job =
        %{"newsletter_send_id" => Ash.UUID.generate()}
        |> KilnCMS.Newsletter.SendWorker.new()
        |> Oban.insert!()

      assert %{cancelled: 1} = Oban.drain_queue(queue: :newsletter)
      assert KilnCMS.Repo.get!(Oban.Job, job.id).state == "cancelled"
    end
  end
end
