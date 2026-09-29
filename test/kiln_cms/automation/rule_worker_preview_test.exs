defmodule KilnCMS.Automation.RuleWorkerPreviewTest do
  @moduledoc """
  `RuleWorker.preview/4` — what a rule would do, described by the same
  templating and guards the real reaction uses, with every side effect left
  out.
  """
  use KilnCMS.DataCase, async: true

  import Swoosh.TestAssertions

  alias KilnCMS.Automation.RuleWorker
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.CMS.HealthSweep

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "preview-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp page(author, title \\ "Field guide") do
    CMS.create_page!(
      %{title: title, slug: "preview-#{System.unique_integer([:positive])}"},
      actor: author
    )
  end

  # The payload as each event's own builder makes it, through JSON — the
  # health sweep's narrow map for a health event, the serialized document for
  # an editorial one.
  defp payload("page.health_overdue", record),
    do: json(HealthSweep.event_payload(record, :overdue))

  defp payload(_event, record), do: json(ContentSerializer.to_map(record))

  defp json(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp preview(action, config, record, event \\ "page.published") do
    RuleWorker.preview(
      %{action: action, config: config, org_id: org_id()},
      event,
      payload(event, record),
      record
    )
  end

  describe "send_email" do
    test "renders the subject and body the real email would carry, and sends nothing" do
      record = page(user(:admin), "Field <b>guide</b>")

      assert [{:email, email}] =
               preview(
                 :send_email,
                 %{"to" => "ed@example.com", "subject" => "Live: {{title}}"},
                 record
               )

      assert email.to == "ed@example.com"
      assert email.subject == "Live: Field <b>guide</b>"
      # The body is HTML, so a title's markup is escaped — as in the real mail.
      assert email.body_html =~ "Field &lt;b&gt;guide&lt;/b&gt;"
      assert email.body_html =~ "page.published"
      assert_no_email_sent()
    end

    test "with no subject, uses the real default" do
      assert [{:email, %{subject: "Kiln automation: Field guide"}}] =
               preview(:send_email, %{}, page(user(:admin)))
    end
  end

  describe "create_task" do
    test "assigns the author when they're an editor, due by the configured days" do
      author = user(:editor)
      record = page(author)

      assert [{:task, task}] =
               preview(
                 :create_task,
                 %{"due_in_days" => 3, "note" => "Re-read {{title}}"},
                 record,
                 "page.health_overdue"
               )

      assert task.assignee_id == author.id
      assert task.due_on == Date.add(Date.utc_today(), 3)
      assert task.note == "Re-read Field guide"

      # Described, not created.
      assert CMS.list_open_tasks_of_kind!("page", record.id, :lifecycle_review,
               authorize?: false,
               tenant: org_id()
             ) == []
    end

    test "on an editorial event it has no author to assign — as the real reaction wouldn't" do
      # Only the health sweep's payload names the author; a publish carries the
      # serialized document, which doesn't. With no fallback, the real worker
      # creates nothing, and the preview has to say the same.
      assert [{:skipped, :no_assignee}] = preview(:create_task, %{}, page(user(:editor)))
    end

    test "says nothing would happen when an open review task already covers it" do
      author = user(:editor)
      record = page(author)

      {:ok, _task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: record.id,
            assignee_id: author.id,
            due_on: Date.add(Date.utc_today(), 3),
            kind: :lifecycle_review
          },
          actor: author,
          tenant: org_id()
        )

      assert [{:skipped, :task_already_open}] =
               preview(:create_task, %{}, record, "page.health_overdue")
    end
  end

  describe "the rest" do
    test "broadcast names the namespaced channel" do
      assert [{:broadcast, %{topic: "automation:editorial", event: "page.published"}}] =
               preview(:broadcast, %{"topic" => "editorial"}, page(user(:admin)))
    end

    test "a newsletter for a translation says it would be skipped" do
      record = %{page(user(:admin)) | locale: "fr"}
      assert [{:skipped, :non_default_locale}] = preview(:newsletter, %{}, record)
    end

    test "a newsletter subject defaults to the title" do
      assert [{:newsletter, %{subject: "Field guide", segment_id: nil}}] =
               preview(:newsletter, %{}, page(user(:admin)))
    end

    test "social post with no network yet asks for one" do
      assert [{:social, %{provider: nil, accounts: 0}}] =
               preview(:social_post, %{}, page(user(:admin)))
    end

    test "social post composes the text even with no account to post it from" do
      assert [{:social, social}] =
               preview(
                 :social_post,
                 %{"provider" => "mastodon", "template" => "New: {{title}}"},
                 page(user(:admin))
               )

      assert social.provider == "mastodon"
      assert social.accounts == 0
      assert social.text == "New: Field guide"
    end

    test "the intelligence reactions are described, not run" do
      for action <- [:flag_duplicates, :suggest_tags, :suggest_links, :suggest_metadata] do
        assert [{:analysis, %{action: ^action, deliver_as: "comment"}}] =
                 preview(action, %{"deliver_as" => "comment"}, page(user(:admin)))
      end
    end
  end
end
