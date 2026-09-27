defmodule KilnCMS.DeprecationsTest do
  @moduledoc """
  The first use of the deprecation policy (#1538): each surface 0.12 deprecates
  keeps working, and says so where someone will see it — the compiler for a
  `use` option, the log for what the compiler never sees. `mix kiln.deprecations`
  finds the data a 1.0 upgrade would strand.

  The editor route aliases are covered in `KilnCMSWeb.EditorLiveTest`.
  """
  # async: false — `Oban.Job` rows and the node-wide warn-once table are shared.
  use KilnCMS.DataCase, async: false
  # The tests that care capture the log themselves; the rest is noise.
  @moduletag :capture_log

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Ash.Query

  alias KilnCMS.Accounts
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

  describe "published?: on use KilnCMS.CMS.Content" do
    test "warns at compile time, at the overlay's own use line" do
      module = :"Elixir.KilnCMS.CMS.DeprecatedPublishedOpt#{System.unique_integer([:positive])}"

      source = """
      defmodule #{inspect(module)} do
        use KilnCMS.CMS.Content,
          type: :page,
          table: "pages",
          published?: true
      end
      """

      stderr =
        capture_io(:stderr, fn ->
          # The warning is raised while the macro expands; whether the rest of
          # a throwaway resource compiles is beside the point here.
          try do
            Code.compile_string(source, "test/deprecated_published_opt.exs")
          rescue
            _ -> :ok
          end
        end)

      assert stderr =~ "the `published?:` option to `use KilnCMS.CMS.Content` is deprecated"
      assert stderr =~ "remove it. 1.0 removes the option."
      assert stderr =~ "test/deprecated_published_opt.exs:2"
      refute stderr =~ "unknown option"
    end

    test "an unknown option warns too, naming it" do
      module = :"Elixir.KilnCMS.CMS.UnknownContentOpt#{System.unique_integer([:positive])}"

      source = """
      defmodule #{inspect(module)} do
        use KilnCMS.CMS.Content,
          type: :page,
          table: "pages",
          exerpt?: true
      end
      """

      stderr =
        capture_io(:stderr, fn ->
          try do
            Code.compile_string(source, "test/unknown_content_opt.exs")
          rescue
            _ -> :ok
          end
        end)

      assert stderr =~ "unknown option(s) [:exerpt?] to `use KilnCMS.CMS.Content` are ignored"
      assert stderr =~ "2.0 makes an unknown option a compile error"
      assert stderr =~ "test/unknown_content_opt.exs:2"
      refute stderr =~ "the `published?:` option"
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

    test "no core content type passes it" do
      for module <- [KilnCMS.CMS.Page, KilnCMS.CMS.Post] do
        source = module.module_info(:compile)[:source] |> to_string() |> File.read!()
        refute source =~ "published?:", "#{inspect(module)} still passes published?:"
      end
    end
  end

  describe "the legacy User.audiences fallback" do
    test "still grants a membership-less account, and warns once per account" do
      reader = user(%{audiences: [@gated]})
      page = gated_page()

      log = capture_log(fn -> assert can_read?(reader, page) end)
      assert log =~ "Account #{reader.id} reads gated content through the deprecated"
      assert log =~ "mix kiln.deprecations --migrate-audiences"

      # Once per account per boot: the fallback runs on every policy check.
      refute capture_log(fn -> assert can_read?(reader, page) end) =~ "deprecated"
    end

    test "stays quiet for an account the fallback grants nothing" do
      reader = user(%{audiences: []})
      page = gated_page()

      log = capture_log(fn -> refute can_read?(reader, page) end)
      refute log =~ "User.audiences fallback"
    end

    test "stays quiet for a member" do
      reader = user(%{audiences: [@gated]})

      Ash.Seed.seed!(OrgMembership, %{
        organization_id: default_org_id(),
        user_id: reader.id,
        role: :viewer,
        audiences: [@gated]
      })

      page = gated_page()

      log = capture_log(fn -> assert can_read?(reader, page) end)
      refute log =~ "User.audiences fallback"
    end
  end

  describe "report/0 and migrate_legacy_audiences/0" do
    test "lists exactly the accounts on the fallback, and migration keeps their access" do
      legacy = user(%{audiences: [@gated], role: :editor})
      _no_audiences = user(%{audiences: []})
      member = user(%{audiences: [@gated]})

      Ash.Seed.seed!(OrgMembership, %{
        organization_id: default_org_id(),
        user_id: member.id,
        role: :viewer,
        audiences: []
      })

      ids = Enum.map(Deprecations.report().legacy_audience_accounts, & &1.id)
      assert legacy.id in ids
      refute member.id in ids
      assert length(ids) == 1

      assert {:ok, [migrated]} = Deprecations.migrate_legacy_audiences()
      assert migrated.id == legacy.id

      membership =
        Accounts.get_org_membership!(legacy.id, default_org_id(), authorize?: false)

      assert membership.audiences == [@gated]
      assert membership.role == :editor
      assert Deprecations.report().legacy_audience_accounts == []

      # Same access as before, now through the membership — and no warning.
      page = gated_page()
      reloaded = Accounts.get_user!(legacy.id, authorize?: false)
      log = capture_log(fn -> assert can_read?(reloaded, page) end)
      refute log =~ "User.audiences fallback"
    end

    test "migration carries a live temporary role, with its expiry" do
      expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      legacy =
        user(%{
          audiences: [@gated],
          role: :viewer,
          granted_role: :editor,
          granted_role_expires_at: expires
        })

      assert {:ok, [_]} = Deprecations.migrate_legacy_audiences()

      membership =
        Accounts.get_org_membership!(legacy.id, default_org_id(), authorize?: false)

      assert membership.role == :viewer
      assert membership.granted_role == :editor
      assert DateTime.compare(membership.granted_role_expires_at, expires) == :eq
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
  end

  describe "run_and_report/2 (mix kiln.deprecations)" do
    test "is :ok on a clean instance, and an error listing what is left otherwise" do
      assert :ok = Deprecations.run_and_report([], fn _ -> :ok end)

      legacy = user(%{audiences: [@gated]})
      {:ok, lines} = Agent.start_link(fn -> [] end)
      shell = fn line -> Agent.update(lines, &[line | &1]) end

      assert {:error, _} = Deprecations.run_and_report([], shell)
      printed = lines |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("\n")
      assert printed =~ "Accounts on the legacy User.audiences fallback: 1"
      assert printed =~ to_string(legacy.email)

      assert :ok = Deprecations.run_and_report([migrate_audiences: true], shell)
    end
  end

  describe "legacy Oban job argument shapes still run, and log" do
    test "a newsletter send job without org_id fans out under the default org" do
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
          assert :ok =
                   KilnCMS.Newsletter.SendWorker.perform(%Oban.Job{
                     args: %{"newsletter_send_id" => send.id}
                   })
        end)

      assert log =~ "KilnCMS.Newsletter.SendWorker job has no `org_id`"
      assert log =~ "Let the queue drain before upgrading to 1.0"

      assert KilnCMS.Newsletter.get_send!(send.id, authorize?: false, tenant: default_org_id()).status ==
               :sent
    end

    test "a newsletter mail job without org_id resolves under the default org" do
      log =
        capture_log(fn ->
          assert {:cancel, "newsletter send " <> _} =
                   KilnCMS.Newsletter.MailWorker.perform(%Oban.Job{
                     args: %{
                       "newsletter_send_id" => Ash.UUID.generate(),
                       "subscriber_id" => Ash.UUID.generate()
                     }
                   })
        end)

      assert log =~ "KilnCMS.Newsletter.MailWorker job has no `org_id`"
    end

    test "a webhook delivery job without org_id settles under the default org" do
      Req.Test.stub(KilnCMS.Webhooks, fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)
      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())

      delivery =
        CMS.create_webhook_delivery!(
          %{endpoint_id: endpoint.id, event: "page.published", payload: %{}},
          authorize?: false
        )

      log =
        capture_log(fn ->
          assert :ok =
                   KilnCMS.Webhooks.DeliveryWorker.perform(%Oban.Job{
                     args: %{"delivery_id" => delivery.id},
                     attempt: 1,
                     max_attempts: 5
                   })
        end)

      assert log =~ "KilnCMS.Webhooks.DeliveryWorker job has no `org_id`"
      assert CMS.get_webhook_delivery!(delivery.id, authorize?: false).status == :succeeded
    end

    test "a pre-ledger webhook job is still delivered" do
      test_pid = self()

      Req.Test.stub(KilnCMS.Webhooks, fn conn ->
        send(test_pid, :delivered)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())

      log =
        capture_log(fn ->
          assert :ok =
                   KilnCMS.Webhooks.DeliveryWorker.perform(%Oban.Job{
                     args: %{
                       "endpoint_id" => endpoint.id,
                       "event" => "page.published",
                       "payload" => %{}
                     }
                   })
        end)

      assert_received :delivered
      assert log =~ "has the pre-ledger `endpoint_id` shape"
    end
  end
end
