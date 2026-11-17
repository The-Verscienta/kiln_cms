defmodule KilnCMS.Notifications.QueuedMailTest do
  @moduledoc """
  Workflow and task mail decides at send time, not only at enqueue (#3019).

  A mail job can wait hours for a retry (`KilnCMS.Mail.backoff_seconds/1`).
  The jobs now carry ids, and the workers read the recipient, the address,
  the actor's name, the title, the comment and the task back when they run:
  an account erased or a preference turned off in the meantime gets nothing,
  an actor erased in the meantime is "An editor", and content, a comment or a
  task gone since sends nothing.

  The "legacy jobs" blocks run the shape the release before queued, with the
  address and the quoted values in the args: delivered only while an account
  that existed at enqueue still holds the address, and its private keys are
  dropped once the job finishes. The last block is erasure's own step: the
  finished account-mail rows addressed to the person lose the address.

  Jobs are queued the real way (through the dispatch paths) wherever one
  exists; the legacy and finished rows are written directly, as an earlier
  release left them.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Notifications.TaskDigestWorker
  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Notifications.WorkflowMailWorker

  defp unique, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "queued-mail-#{unique()}@example.com",
          name: "Person #{unique()}",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp erase!(user), do: Accounts.anonymize_user!(user, actor: user(:admin))

  defp address(user), do: to_string(user.email)

  # Neither the address an erased account had nor the tombstone that replaced
  # it may receive anything.
  defp nothing_to(emails, user, old_address) do
    assert to(emails, old_address) == []
    assert to(emails, "anonymized-#{user.id}@deleted.invalid") == []
  end

  defp tenant, do: Accounts.default_org_id()

  defp drain, do: KilnCMS.DataCase.drain_oban()

  # Every email delivered to this process so far, consumed.
  defp emails do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end

  defp to(emails, address),
    do: Enum.filter(emails, fn email -> Enum.any?(email.to, &(elem(&1, 1) == address)) end)

  defp page!(author, title \\ nil) do
    CMS.create_page!(
      %{
        title: title || "Queued #{unique()}",
        slug: "queued-#{unique()}",
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "Body", data: %{"level" => 2}, order: 0}
          ])
      },
      actor: author
    )
  end

  defp block_id(page) do
    page = CMS.get_page!(page.id, authorize?: false)
    page.blocks |> hd() |> Map.get(:value) |> Map.get(:id)
  end

  defp comment!(page, body, actor) do
    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: block_id(page), body: body},
      actor: actor
    )
  end

  defp handle(user), do: "@" <> String.replace(String.downcase(user.name), ~r/[^a-z0-9]/, "")

  defp assign!(assignee, attrs \\ %{}) do
    {:ok, task} =
      CMS.assign_task(
        Map.merge(
          %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id},
          attrs
        ),
        actor: user(:editor)
      )

    task
  end

  defp jobs(worker), do: all_enqueued(worker: worker)

  defp jobs_for(worker, user), do: Enum.filter(jobs(worker), &(&1.args["user_id"] == user.id))

  defp row(id), do: Repo.one!(from(j in Oban.Job, where: j.id == ^id))

  # Every arg of every job row, as JSON: what `oban_jobs` holds.
  defp all_args_json, do: Repo.all(from(j in Oban.Job, select: j.args)) |> Jason.encode!()

  describe "the args carry ids, not the mail (#3019)" do
    test "a review request: no address, title or actor name, and no `to` or `title` key" do
      admin = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)

      assert [job] = jobs_for(WorkflowMailWorker, admin)
      json = Jason.encode!(job.args)

      # The previous release's worker needs `to` and `title` to build its
      # email: without them an old node fails the job and a new node retries
      # it, instead of the old node sending it to nobody.
      refute Map.has_key?(job.args, "to")
      refute Map.has_key?(job.args, "title")
      refute Map.has_key?(job.args, "actor_name")
      refute json =~ address(admin)
      refute json =~ page.title
      refute json =~ editor.name

      assert job.args["kind"] == "page"
      assert job.args["id"] == page.id
      assert job.args["actor_id"] == editor.id
    end

    test "a comment: the comment's id, never its words" do
      author = user(:editor)
      commenter = user(:editor)
      page = page!(author)
      comment = comment!(page, "a private review note #{unique()}", commenter)

      assert [job] = jobs_for(WorkflowMailWorker, author)
      json = Jason.encode!(job.args)

      refute Map.has_key?(job.args, "excerpt")
      refute json =~ comment.body
      refute json =~ address(author)
      assert job.args["comment_id"] == comment.id
      assert job.args["block_id"] == comment.block_id
    end

    test "a task assignment: no `kind`, no `to`, no note" do
      assignee = user(:editor)
      task = assign!(assignee, %{note: "note #{unique()}"})

      assert [job] = jobs_for(TaskMailWorker, assignee)
      json = Jason.encode!(job.args)

      # The previous release's clauses match on `kind` alone and would build
      # an email with no recipient from this job; without it they fail it.
      refute Map.has_key?(job.args, "kind")
      refute Map.has_key?(job.args, "to")
      refute json =~ task.note
      refute json =~ address(assignee)
      assert job.args["event"] == "assigned"
      assert job.args["task_id"] == task.id
    end

    test "a digest: the assignee's id, no `kind` and no `to`" do
      assignee = user(:editor)
      assign!(assignee, %{due_on: Date.utc_today()})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))

      assert [job] =
               jobs(TaskMailWorker) |> Enum.filter(&(&1.args["event"] == "digest"))

      refute Map.has_key?(job.args, "kind")
      refute Map.has_key?(job.args, "to")
      refute Jason.encode!(job.args) =~ address(assignee)
      assert job.args["user_id"] == assignee.id
    end
  end

  describe "an account erased before the job runs is sent nothing" do
    test "a review request" do
      erased = user(:admin)
      live = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      [job] = jobs_for(WorkflowMailWorker, erased)
      old_address = address(erased)

      erase!(erased)
      drain()

      sent = emails()
      # Not vacuous: the admin who was not erased is asked.
      assert [_review] = to(sent, address(live))
      nothing_to(sent, erased, old_address)
      assert row(job.id).state == "completed"
      refute all_args_json() =~ old_address
    end

    test "a comment on their thread" do
      author = user(:editor)
      participant = user(:editor)
      page = page!(author)
      comment!(page, "first", participant)
      drain()
      emails()

      comment!(page, "second", user(:editor))
      old_address = address(participant)
      erase!(participant)
      drain()

      sent = emails()
      assert [_comment] = to(sent, address(author))
      nothing_to(sent, participant, old_address)
    end

    test "a mention" do
      author = user(:editor)
      mentioned = user(:editor)
      page = page!(author)
      comment!(page, "over to you #{handle(mentioned)}", user(:editor))
      assert [%{args: %{"event" => "comment_mention"}}] = jobs_for(WorkflowMailWorker, mentioned)

      old_address = address(mentioned)
      erase!(mentioned)
      drain()

      sent = emails()
      assert [_comment] = to(sent, address(author))
      nothing_to(sent, mentioned, old_address)
    end

    test "a task assignment" do
      erased = user(:editor)
      live = user(:editor)
      assign!(erased)
      assign!(live)
      old_address = address(erased)

      erase!(erased)
      drain()

      sent = emails()
      assert [_assigned] = to(sent, address(live))
      nothing_to(sent, erased, old_address)
    end

    test "a task digest" do
      erased = user(:editor)
      live = user(:editor)
      assign!(erased, %{due_on: Date.utc_today()})
      assign!(live, %{due_on: Date.utc_today()})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))
      old_address = address(erased)
      erase!(erased)
      drain()

      sent = emails()
      assert [digest] = to(sent, address(live))
      assert digest.subject =~ "Your task digest"
      nothing_to(sent, erased, old_address)
    end
  end

  describe "what changed since the job was queued" do
    test "a review request muted since is not sent" do
      admin = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      assert [_job] = jobs_for(WorkflowMailWorker, admin)

      Accounts.update_notification_prefs!(admin, %{notify_on_review_request: false}, actor: admin)
      drain()

      assert to(emails(), address(admin)) == []
    end

    test "a comment muted since is not sent" do
      author = user(:editor)
      page = page!(author)
      comment!(page, "hello", user(:editor))
      assert [_job] = jobs_for(WorkflowMailWorker, author)

      Accounts.update_notification_prefs!(author, %{notify_on_comment: false}, actor: author)
      drain()

      assert to(emails(), address(author)) == []
    end

    test "a task assignment has no preference, so muting everything still sends it" do
      assignee = user(:editor)
      assign!(assignee)

      Accounts.update_notification_prefs!(
        assignee,
        %{
          notify_on_review_request: false,
          notify_on_publish: false,
          notify_on_return_to_draft: false,
          notify_on_comment: false
        },
        actor: assignee
      )

      drain()

      assert [_assigned] = to(emails(), address(assignee))
    end

    test "an actor erased since is \"An editor\", and their name is not in the mail" do
      admin = user(:admin)
      editor = user(:editor)
      old_name = editor.name
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)

      erase!(editor)
      drain()

      assert [review] = to(emails(), address(admin))
      assert review.html_body =~ "An editor submitted"
      refute review.html_body =~ old_name
      refute review.subject =~ old_name
    end

    test "a commenter erased since is \"An editor\" in a mention's subject" do
      author = user(:editor)
      mentioned = user(:editor)
      commenter = user(:editor)
      old_name = commenter.name
      page = page!(author)
      comment!(page, "see #{handle(mentioned)}", commenter)

      erase!(commenter)
      drain()

      assert [mention] = to(emails(), address(mentioned))
      assert mention.subject =~ "An editor mentioned you"
      refute mention.subject =~ old_name
      refute mention.html_body =~ old_name
    end

    test "an assigner erased since is \"An editor\" in the task mail" do
      assignee = user(:editor)
      assigner = user(:editor)
      old_name = assigner.name

      {:ok, _task} =
        CMS.assign_task(
          %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id},
          actor: assigner
        )

      erase!(assigner)
      drain()

      assert [assigned] = to(emails(), address(assignee))
      assert assigned.html_body =~ "An editor assigned you"
      refute assigned.html_body =~ old_name
    end

    # No action changes an address once an account exists, so the row is
    # written directly: what matters is that the worker reads it at send time.
    test "the mail goes to the address the account holds when it is sent" do
      admin = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      old_address = address(admin)
      new_address = "queued-mail-moved-#{unique()}@example.com"

      Ash.Seed.update!(admin, %{email: new_address})
      drain()

      sent = emails()
      assert [_review] = to(sent, new_address)
      assert to(sent, old_address) == []
    end
  end

  describe "the source gone since sends nothing" do
    test "a page trashed since" do
      admin = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      [job] = jobs_for(WorkflowMailWorker, admin)

      CMS.destroy_page!(page, actor: admin)
      drain()

      assert Enum.filter(emails(), &(&1.subject =~ page.title)) == []
      assert row(job.id).state == "completed"
    end

    test "a comment deleted since" do
      author = user(:editor)
      page = page!(author)
      comment = comment!(page, "gone soon", user(:editor))
      [job] = jobs_for(WorkflowMailWorker, author)

      # No action deletes a comment; content purge cascades the same way.
      Repo.delete_all(from(c in "comments", where: c.id == type(^comment.id, Ecto.UUID)))
      drain()

      assert to(emails(), address(author)) == []
      assert row(job.id).state == "completed"
    end

    test "a task completed since" do
      assignee = user(:editor)
      task = assign!(assignee)
      CMS.complete_task!(task, %{}, actor: assignee)
      drain()

      assert to(emails(), address(assignee)) == []
    end

    test "a task reassigned since goes to the new assignee only" do
      first = user(:editor)
      second = user(:editor)
      task = assign!(first)
      CMS.update_task!(task, %{assignee_id: second.id}, actor: user(:editor))
      drain()

      sent = emails()
      assert to(sent, address(first)) == []
      assert [_assigned] = to(sent, address(second))
    end

    test "a task's note is read when the mail is sent" do
      assignee = user(:editor)
      task = assign!(assignee, %{note: "first draft of the note"})
      CMS.update_task!(task, %{note: "the note as it is now"}, actor: user(:editor))
      drain()

      assert [assigned] = to(emails(), address(assignee))
      assert assigned.html_body =~ "the note as it is now"
      refute assigned.html_body =~ "first draft of the note"
    end

    test "a digest whose content is gone keeps its line, titled by the type" do
      assignee = user(:editor)
      assign!(assignee, %{due_on: Date.utc_today()})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))
      drain()

      assert [digest] = to(emails(), address(assignee))
      assert digest.html_body =~ ">page</a>"
    end
  end

  describe "legacy jobs, queued before #3019 with the address in their args" do
    # As the release before queued it. `inserted_at` is set from the app's
    # clock: in the test's sandbox transaction the column default is the
    # transaction's start, which would make every account seeded in the test
    # look younger than the job.
    defp legacy!(worker, args) do
      job = args |> worker.new() |> Oban.insert!()

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [inserted_at: DateTime.utc_now()]
      )

      job
    end

    defp legacy_review(to, title) do
      %{
        "to" => to,
        "event" => "submitted_for_review",
        "kind" => "page",
        "title" => title,
        "id" => Ecto.UUID.generate(),
        "actor_name" => "Legacy Actor",
        "org_id" => tenant()
      }
    end

    defp legacy_assigned(to) do
      %{
        "kind" => "assigned",
        "to" => to,
        "task_id" => Ecto.UUID.generate(),
        "content_type" => "page",
        "content_id" => Ecto.UUID.generate(),
        "block_id" => nil,
        "org_id" => tenant(),
        "due_on" => nil,
        "note" => "legacy note",
        "actor_name" => "Legacy Actor"
      }
    end

    test "a review request to a live account is delivered, and the row forgets the address" do
      admin = user(:admin)
      title = "Legacy #{unique()}"
      job = legacy!(WorkflowMailWorker, legacy_review(address(admin), title))
      drain()

      assert [review] = to(emails(), address(admin))
      assert review.subject == "Review requested: #{title}"
      assert review.html_body =~ "Legacy Actor"

      row = row(job.id)
      assert row.state == "completed"
      for key <- ~w(to title actor_name excerpt), do: refute(Map.has_key?(row.args, key))
    end

    test "a review request to an account erased since is not sent, and forgets the address" do
      admin = user(:admin)
      old_address = address(admin)
      job = legacy!(WorkflowMailWorker, legacy_review(old_address, "Legacy #{unique()}"))

      erase!(admin)
      drain()

      nothing_to(emails(), admin, old_address)
      row = row(job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "to")
      refute all_args_json() =~ old_address
    end

    test "an address registered again since the job was queued is somebody else" do
      admin = user(:admin)
      old_address = address(admin)
      job = legacy!(WorkflowMailWorker, legacy_review(old_address, "Legacy #{unique()}"))

      erase!(admin)
      user(:admin, %{email: old_address})
      drain()

      assert to(emails(), old_address) == []
      assert row(job.id).state == "completed"
    end

    test "a muted event is not sent" do
      admin = user(:admin, %{notify_on_review_request: false})
      legacy!(WorkflowMailWorker, legacy_review(address(admin), "Legacy #{unique()}"))
      drain()

      assert to(emails(), address(admin)) == []
    end

    test "a task assignment to a live account is delivered, and forgets the address and note" do
      assignee = user(:editor)
      job = legacy!(TaskMailWorker, legacy_assigned(address(assignee)))
      drain()

      assert [assigned] = to(emails(), address(assignee))
      assert assigned.html_body =~ "legacy note"

      row = row(job.id)
      assert row.state == "completed"
      for key <- ~w(to note actor_name), do: refute(Map.has_key?(row.args, key))
      assert row.args["kind"] == "assigned"
    end

    test "a task assignment to an account erased since is not sent" do
      assignee = user(:editor)
      old_address = address(assignee)
      job = legacy!(TaskMailWorker, legacy_assigned(old_address))

      erase!(assignee)
      drain()

      nothing_to(emails(), assignee, old_address)
      refute Map.has_key?(row(job.id).args, "to")
    end

    test "a digest to a live account is delivered" do
      assignee = user(:editor)

      job =
        legacy!(TaskMailWorker, %{
          "kind" => "digest",
          "to" => address(assignee),
          "org_id" => tenant(),
          "items" => [
            %{
              "content_type" => "page",
              "content_id" => Ecto.UUID.generate(),
              "due_on" => Date.to_iso8601(Date.utc_today())
            }
          ]
        })

      drain()

      assert [digest] = to(emails(), address(assignee))
      assert digest.subject == "Your task digest: 1 item"
      refute Map.has_key?(row(job.id).args, "to")
    end
  end

  describe "a job holding neither shape" do
    # A legacy job whose keys `finishing/3` already dropped, re-queued by
    # Lifeline: the mail went out, so it completes (not cancels: a cancelled
    # mail job reads as a delivery failure on /editor/mail) and sends nothing.
    test "both workers complete it and send nothing" do
      assert :ok =
               perform_job(WorkflowMailWorker, %{
                 "event" => "submitted_for_review",
                 "kind" => "page",
                 "id" => Ecto.UUID.generate()
               })

      assert :ok =
               perform_job(TaskMailWorker, %{
                 "kind" => "assigned",
                 "task_id" => Ecto.UUID.generate()
               })

      assert emails() == []
    end
  end

  describe "erasure drops the address from finished mail jobs" do
    defp mail_row!(worker, args, state) do
      job = args |> worker.new() |> Oban.insert!()
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
      job
    end

    test "account mail and legacy workflow mail, finished, lose the address" do
      person = user(:editor)
      bystander = user(:editor)
      addr = address(person)

      delivered = mail_row!(DeliveryWorker, %{"to" => ["Person", addr]}, "completed")
      bounced = mail_row!(DeliveryWorker, %{"to" => ["", String.upcase(addr)]}, "cancelled")

      workflow =
        mail_row!(WorkflowMailWorker, legacy_review(addr, "Legacy #{unique()}"), "discarded")

      pending = mail_row!(DeliveryWorker, %{"to" => ["", addr]}, "available")
      other = mail_row!(DeliveryWorker, %{"to" => ["", address(bystander)]}, "completed")

      erase!(person)

      for job <- [delivered, bounced, workflow] do
        refute Map.has_key?(row(job.id).args, "to")
      end

      # The rest of a finished row stays: only the address goes.
      assert row(workflow.id).args["event"] == "submitted_for_review"
      # A job still waiting to run is withheld (#3035,
      # `KilnCMS.Mail.AccountMailErasureTest`); another person's row is untouched.
      assert row(pending.id).args["withheld"] == "erased"
      refute Map.has_key?(row(pending.id).args, "to")
      assert row(other.id).args["to"] == ["", address(bystander)]
    end
  end
end
