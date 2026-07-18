defmodule KilnCMS.AutomationTest do
  @moduledoc "Oban-backed editorial automation — Directus Flows answer (#342)."
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Swoosh.TestAssertions

  alias KilnCMS.Automation
  alias KilnCMS.Automation.DispatchWorker
  alias KilnCMS.Automation.Rule
  alias KilnCMS.Automation.RuleWorker
  alias KilnCMS.CMS

  defp rule(attrs) do
    Ash.Seed.seed!(
      Rule,
      Map.merge(
        %{name: "Rule #{System.unique_integer([:positive])}", enabled: true, config: %{}},
        attrs
      )
    )
  end

  defp payload(overrides \\ %{}) do
    Map.merge(%{"id" => Ash.UUID.generate(), "title" => "Hello", "slug" => "hello"}, overrides)
  end

  describe "handle_event/2 (on the publish path)" do
    test "enqueues a DispatchWorker for a supported event (no DB read on the publish path)" do
      Automation.handle_event("post.published", payload())
      assert_enqueued(worker: DispatchWorker, args: %{"event" => "post.published"})
    end

    test "ignores unsupported events without enqueuing or raising" do
      assert :ok = Automation.handle_event("form.submitted", payload())
      assert :ok = Automation.handle_event("garbage", payload())
      refute_enqueued(worker: DispatchWorker)
    end
  end

  describe "dispatch/2 rule matching" do
    test "enqueues a worker for a matching enabled rule" do
      r = rule(%{trigger_event: :published, action: :broadcast})
      Automation.dispatch("post.published", payload())
      assert_enqueued(worker: RuleWorker, args: %{"rule_id" => r.id, "event" => "post.published"})
    end

    test "respects the content_type filter" do
      scoped = rule(%{trigger_event: :published, action: :broadcast, content_type: "post"})
      Automation.dispatch("page.published", payload())
      refute_enqueued(worker: RuleWorker, args: %{"rule_id" => scoped.id})

      Automation.dispatch("post.published", payload())
      assert_enqueued(worker: RuleWorker, args: %{"rule_id" => scoped.id})
    end

    test "ignores disabled rules and non-matching triggers" do
      off = rule(%{trigger_event: :published, action: :broadcast, enabled: false})
      other = rule(%{trigger_event: :unpublished, action: :broadcast})

      Automation.dispatch("post.published", payload())
      refute_enqueued(worker: RuleWorker, args: %{"rule_id" => off.id})
      refute_enqueued(worker: RuleWorker, args: %{"rule_id" => other.id})
    end

    test "ignores unsupported events without raising" do
      _r = rule(%{trigger_event: :published, action: :broadcast})
      assert :ok = Automation.dispatch("form.submitted", payload())
      assert :ok = Automation.dispatch("garbage", payload())
    end
  end

  describe "RuleWorker reactions" do
    defp run(rule, event, payload) do
      RuleWorker.perform(%Oban.Job{
        args: %{"rule_id" => rule.id, "event" => event, "payload" => payload}
      })
    end

    test "broadcast publishes an automation event on the (namespaced) configured topic" do
      name = "test-#{System.unique_integer([:positive])}"
      # The worker namespaces the admin-supplied topic so it can't collide with
      # internal topics.
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, "automation:#{name}")
      r = rule(%{trigger_event: :published, action: :broadcast, config: %{"topic" => name}})

      run(r, "post.published", payload())
      assert_receive {:automation_event, "post.published", %{"slug" => "hello"}}
    end

    test "send_email delivers an email with interpolated subject/body" do
      r =
        rule(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team@example.com", "subject" => "Live: {{title}} ({{type}})"}
        })

      run(r, "post.published", payload(%{"title" => "Big News"}))

      assert_email_sent(fn email ->
        assert email.subject == "Live: Big News (post)"
        assert {_, "team@example.com"} = hd(email.to)
      end)
    end

    test "send_email strips CR/LF from a templated title so the subject can't inject headers" do
      r =
        rule(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team@example.com", "subject" => "New: {{title}}"}
        })

      run(r, "post.published", payload(%{"title" => "Hi\r\nBcc: evil@example.com"}))

      assert_email_sent(fn email ->
        refute email.subject =~ "\n"
        refute email.subject =~ "\r"
        assert email.subject == "New: Hi Bcc: evil@example.com"
      end)
    end

    test "reindex re-fires the record" do
      id = Ash.UUID.generate()
      r = rule(%{trigger_event: :published, action: :reindex})

      run(r, "post.published", payload(%{"id" => id}))
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"type" => "post", "id" => id})
    end

    test "invalidate_cache runs without error" do
      r = rule(%{trigger_event: :updated, action: :invalidate_cache})
      assert :ok = run(r, "post.updated", payload())
    end

    test "a disabled-since-enqueue rule is a no-op" do
      r = rule(%{trigger_event: :published, action: :broadcast, enabled: false})
      assert :ok = run(r, "post.published", payload())
    end
  end

  describe "end-to-end from a publish" do
    test "publishing a page fires its matching rule" do
      name = "e2e-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, "automation:#{name}")
      rule(%{trigger_event: :published, action: :broadcast, config: %{"topic" => name}})

      actor =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "auto-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      page =
        CMS.create_page!(%{title: "Auto", slug: "auto-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      CMS.publish_page!(page, actor: actor)
      # The event → rule → worker chain runs on Oban; drain to execute it.
      drain_oban()

      assert_receive {:automation_event, "page.published", %{"title" => "Auto"}}
    end
  end
end
