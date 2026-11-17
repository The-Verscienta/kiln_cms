defmodule KilnCMS.Notifications.SendTimeEntitlementTest do
  @moduledoc """
  Workflow and task mail re-checks, when the job runs, that the recipient is
  still who the event is for (#3037), and skips an address on a suppression
  list (#3036).

  Each event has its own rule, and each is asked again through the function
  the enqueue used:

    * a review request: still an admin of the site
      (`KilnCMS.Accounts.Scoping.has_tier?/3` ⇔ `users_with_tier/2`);
    * published / returned to draft: still the content's author;
    * a comment notice: still on the thread, or the author
      (`KilnCMS.Notifications.comment_audience_ids/2`);
    * a mention: still on the mention roster
      (`KilnCMS.Notifications.mention_roster_member?/2` ⇔ `mention_roster/1`);
    * a task assignment: the task still open and still theirs;
    * a digest: only the lines whose task is still open and theirs.

  Each refused case is paired with someone who is still sent the mail, so a
  test cannot pass by nothing being sent at all. The "equivalence" blocks
  pin the single-account predicates to the rosters they narrow. The "legacy"
  block runs the job shapes v1.10.1 queued.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.Mail
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.TaskDigestWorker
  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Notifications.WorkflowMailWorker

  defp unique, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "entitled-#{unique()}@example.com",
          name: "Person #{unique()}",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp membership!(user, org_id, role, status \\ :active) do
    Ash.Seed.seed!(OrgMembership, %{
      user_id: user.id,
      organization_id: org_id,
      role: role,
      status: status
    })
  end

  defp remove!(membership), do: Accounts.remove_org_membership!(membership, authorize?: false)

  defp tenant, do: Accounts.default_org_id()

  defp address(user), do: to_string(user.email)

  defp drain, do: KilnCMS.DataCase.drain_oban()

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

  defp page!(author) do
    CMS.create_page!(
      %{
        title: "Entitled #{unique()}",
        slug: "entitled-#{unique()}",
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

  # No action deletes one comment; content purge cascades the same way.
  defp delete_comment!(comment),
    do: Repo.delete_all(from(c in "comments", where: c.id == type(^comment.id, Ecto.UUID)))

  defp handle(user), do: "@" <> String.replace(String.downcase(user.name), ~r/[^a-z0-9]/, "")

  # No code interface moves authorship but an import's `:reassign_author`;
  # the row is what the rule reads.
  defp reassign_author!(page, author), do: Ash.Seed.update!(page, %{author_id: author.id})

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

  defp jobs_for(worker, user),
    do: Enum.filter(all_enqueued(worker: worker), &(&1.args["user_id"] == user.id))

  defp row(id), do: Repo.one!(from(j in Oban.Job, where: j.id == ^id))

  defp suppress!(address), do: Mail.suppress_recipient!(%{email: address}, authorize?: false)

  defp suppress_on_site!(address, org_id),
    do: Mail.suppress_site_recipient!(%{email: address}, tenant: org_id, authorize?: false)

  describe "a review request" do
    test "an admin demoted since is not sent it; an admin still one is" do
      demoted = user(:admin)
      still = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      [job] = jobs_for(WorkflowMailWorker, demoted)

      Ash.Seed.update!(demoted, %{role: :editor})
      drain()

      sent = emails()
      assert [_review] = to(sent, address(still))
      assert to(sent, address(demoted)) == []
      assert row(job.id).state == "completed"
    end

    test "a member admin removed from the site since is not sent it" do
      removed = user(:viewer)
      membership = membership!(removed, tenant(), :admin)
      still = user(:admin)
      editor = user(:editor)
      page = page!(editor)
      CMS.submit_page_for_review!(page, %{}, actor: editor)
      assert [_job] = jobs_for(WorkflowMailWorker, removed)

      remove!(membership)
      drain()

      sent = emails()
      assert [_review] = to(sent, address(still))
      assert to(sent, address(removed)) == []
    end
  end

  describe "an author's notice" do
    test "published: an account no longer the author is not sent it" do
      author = user(:editor)
      page = page!(author)
      CMS.publish_page!(page, %{}, actor: user(:admin))
      assert [_job] = jobs_for(WorkflowMailWorker, author)

      reassign_author!(page, user(:editor))
      drain()

      assert to(emails(), address(author)) == []
    end

    test "published: the author still is is sent it" do
      author = user(:editor)
      page = page!(author)
      CMS.publish_page!(page, %{}, actor: user(:admin))
      drain()

      assert [published] = to(emails(), address(author))
      assert published.subject =~ "Published:"
    end

    test "returned to draft: an account no longer the author is not sent it" do
      author = user(:editor)
      page = page!(author)
      page = CMS.submit_page_for_review!(page, %{}, actor: author)
      admin = user(:admin)
      drain()
      emails()

      CMS.return_page_to_draft!(page, %{}, actor: admin)
      assert [%{args: %{"event" => "returned_to_draft"}}] = jobs_for(WorkflowMailWorker, author)

      reassign_author!(page, user(:editor))
      drain()

      assert to(emails(), address(author)) == []
    end
  end

  describe "a comment notice" do
    test "a participant whose comments are gone from the thread is not sent it" do
      author = user(:editor)
      participant = user(:editor)
      page = page!(author)
      first = comment!(page, "first", participant)
      drain()
      emails()

      comment!(page, "second", user(:editor))
      assert [_job] = jobs_for(WorkflowMailWorker, participant)
      delete_comment!(first)
      drain()

      sent = emails()
      # Not vacuous: the author is still sent it.
      assert [_comment] = to(sent, address(author))
      assert to(sent, address(participant)) == []
    end

    test "an author who is no longer the author, and not on the thread, is not sent it" do
      author = user(:editor)
      participant = user(:editor)
      page = page!(author)
      comment!(page, "first", participant)
      drain()
      emails()

      comment!(page, "second", user(:editor))
      reassign_author!(page, user(:editor))
      drain()

      sent = emails()
      assert [_comment] = to(sent, address(participant))
      assert to(sent, address(author)) == []
    end

    test "resolved: the thread rule applies too" do
      author = user(:editor)
      starter = user(:editor)
      participant = user(:editor)
      page = page!(author)
      # Only a thread's first comment can be resolved.
      root = comment!(page, "first", starter)
      reply = comment!(page, "second", participant)
      drain()
      emails()

      CMS.resolve_comment!(root, %{}, actor: author)

      assert [%{args: %{"event" => "comment_resolved"}}] =
               jobs_for(WorkflowMailWorker, participant)

      delete_comment!(reply)
      drain()

      sent = emails()
      assert [_resolved] = to(sent, address(starter))
      assert to(sent, address(participant)) == []
    end
  end

  describe "a mention" do
    test "someone since scoped to another site only is off the roster and not sent it" do
      mentioned = user(:editor)
      still = user(:editor)
      page = page!(user(:editor))
      comment!(page, "see #{handle(mentioned)} and #{handle(still)}", user(:editor))
      assert [%{args: %{"event" => "comment_mention"}}] = jobs_for(WorkflowMailWorker, mentioned)

      other = KilnCMS.OrgFixtures.org("entitled-other")
      membership!(mentioned, other.id, :editor)
      drain()

      sent = emails()
      assert [_mention] = to(sent, address(still))
      assert to(sent, address(mentioned)) == []
    end

    test "a registration pending on the site is not a member, and is not sent it" do
      mentioned = user(:editor)
      page = page!(user(:editor))
      comment!(page, "see #{handle(mentioned)}", user(:editor))
      assert [_job] = jobs_for(WorkflowMailWorker, mentioned)

      membership!(mentioned, tenant(), :editor, :pending)
      drain()

      assert to(emails(), address(mentioned)) == []
    end

    # `dispatch_comment/4` takes a mentioned participant out of the thread
    # audience, so the mention is their only notice of the comment.
    test "a participant also mentioned is still sent it off the roster; a non-participant is not" do
      participant = user(:editor)
      bystander = user(:editor)
      page = page!(user(:editor))
      comment!(page, "first", participant)
      drain()
      emails()

      comment!(page, "see #{handle(participant)} and #{handle(bystander)}", user(:editor))

      for person <- [participant, bystander] do
        assert [%{args: %{"event" => "comment_mention"}}] = jobs_for(WorkflowMailWorker, person)
      end

      other = KilnCMS.OrgFixtures.org("entitled-mention-thread")
      membership!(participant, other.id, :editor)
      membership!(bystander, other.id, :editor)
      drain()

      sent = emails()
      assert [mention] = to(sent, address(participant))
      assert mention.subject =~ "mentioned you"
      assert to(sent, address(bystander)) == []
    end
  end

  describe "a task digest" do
    test "lists only the tasks still open and still theirs, and counts those" do
      assignee = user(:editor)
      kept = assign!(assignee, %{due_on: Date.utc_today()})
      moved = assign!(assignee, %{due_on: Date.utc_today()})
      done = assign!(assignee, %{due_on: Date.utc_today()})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))

      assert [%{args: %{"items" => items}}] =
               all_enqueued(worker: TaskMailWorker)
               |> Enum.filter(&(&1.args["event"] == "digest"))

      assert items |> Enum.map(& &1["task_id"]) |> Enum.sort() ==
               Enum.sort([kept.id, moved.id, done.id])

      CMS.update_task!(moved, %{assignee_id: user(:editor).id}, actor: user(:editor))
      CMS.complete_task!(done, %{}, actor: assignee)
      drain()

      assert [digest] = to(emails(), address(assignee))
      assert digest.subject == "Your task digest: 1 item"
      assert digest.html_body =~ "You have 1 open task"
    end

    test "with no task left, nothing is sent" do
      assignee = user(:editor)
      task = assign!(assignee, %{due_on: Date.utc_today()})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))
      CMS.complete_task!(task, %{}, actor: assignee)
      drain()

      assert to(emails(), address(assignee)) == []
    end

    test "with the grant gone, the digest job fails rather than sending nothing" do
      assignee = user(:editor)
      assign!(assignee, %{due_on: Date.utc_today()})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))

      assert [job] =
               all_enqueued(worker: TaskMailWorker)
               |> Enum.filter(&(&1.args["event"] == "digest"))

      assert {:error, %Ash.Error.Forbidden{}} =
               Notifications.with_actor(nil, fn -> TaskMailWorker.perform(job) end)

      # Not vacuous: with the grant, the same job delivers.
      assert :ok = TaskMailWorker.perform(job)
      assert [_digest] = to(emails(), address(assignee))
    end

    test "each line shows its task's due date now, not the one it was queued with" do
      assignee = user(:editor)
      today = Date.utc_today()
      moved_to = Date.add(today, 2)
      task = assign!(assignee, %{due_on: today})
      drain()
      emails()

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(today, 3))
      CMS.update_task!(task, %{due_on: moved_to}, actor: user(:editor))
      drain()

      assert [digest] = to(emails(), address(assignee))
      assert digest.html_body =~ Date.to_iso8601(moved_to)
      refute digest.html_body =~ Date.to_iso8601(today)
    end
  end

  describe "the suppression lists (#3036)" do
    test "an address on the instance-wide list is not sent a review request" do
      suppressed = user(:admin)
      still = user(:admin)
      editor = user(:editor)
      CMS.submit_page_for_review!(page!(editor), %{}, actor: editor)
      [job] = jobs_for(WorkflowMailWorker, suppressed)

      # Case-insensitive, as every lookup of the list is.
      suppress!(String.upcase(address(suppressed)))
      drain()

      sent = emails()
      assert [_review] = to(sent, address(still))
      assert to(sent, address(suppressed)) == []
      # A skip, not a cancel: a cancelled mail job reads as a delivery failure.
      assert row(job.id).state == "completed"
    end

    test "an address on the site's own list is not sent a comment notice" do
      author = user(:editor)
      comment!(page!(author), "hello", user(:editor))
      suppress_on_site!(address(author), tenant())
      drain()

      assert to(emails(), address(author)) == []
    end

    test "another site's list does not stop this site's mail" do
      author = user(:editor)
      comment!(page!(author), "hello", user(:editor))
      other = KilnCMS.OrgFixtures.org("entitled-supp")
      suppress_on_site!(address(author), other.id)
      drain()

      assert [_comment] = to(emails(), address(author))
    end

    test "a task assignment and a digest" do
      assignee = user(:editor)
      still = user(:editor)
      assign!(assignee, %{due_on: Date.utc_today()})
      assign!(still, %{due_on: Date.utc_today()})
      suppress!(address(assignee))
      drain()

      assert to(emails(), address(assignee)) == []

      assert :ok = TaskDigestWorker.send_digests(tenant(), Date.add(Date.utc_today(), 3))
      drain()

      sent = emails()
      assert [digest] = to(sent, address(still))
      assert digest.subject =~ "Your task digest"
      assert to(sent, address(assignee)) == []
    end

    test "a list that cannot be read fails the job, which retries" do
      admin = user(:admin)
      editor = user(:editor)
      CMS.submit_page_for_review!(page!(editor), %{}, actor: editor)
      [review] = jobs_for(WorkflowMailWorker, admin)
      assignee = user(:editor)
      assign!(assignee)
      [assigned] = jobs_for(TaskMailWorker, assignee)

      for {worker, job} <- [{WorkflowMailWorker, review}, {TaskMailWorker, assigned}] do
        assert_raise Ash.Error.Forbidden, fn ->
          Mail.with_actor(nil, fn -> worker.perform(job) end)
        end
      end

      assert emails() == []

      # Not vacuous: with the list readable, both deliver.
      assert :ok = WorkflowMailWorker.perform(review)
      assert :ok = TaskMailWorker.perform(assigned)
      sent = emails()
      assert [_review] = to(sent, address(admin))
      assert [_assigned] = to(sent, address(assignee))
    end
  end

  describe "has_tier?/3 answers as users_with_tier/2 does" do
    test "for every kind of account, tier set and org" do
      site = KilnCMS.OrgFixtures.org("entitled-tier")
      elsewhere = KilnCMS.OrgFixtures.org("entitled-elsewhere")

      platform_admin = user(:admin)
      legacy_editor = user(:editor)
      member_admin = user(:viewer)
      membership!(member_admin, site.id, :admin)
      member_editor = user(:viewer)
      membership!(member_editor, site.id, :editor)
      pending_admin = user(:viewer)
      membership!(pending_admin, site.id, :admin, :pending)
      foreign_editor = user(:editor)
      membership!(foreign_editor, elsewhere.id, :editor)
      erased_admin = user(:admin, %{anonymized_at: DateTime.utc_now()})

      people = [
        platform_admin,
        legacy_editor,
        member_admin,
        member_editor,
        pending_admin,
        foreign_editor,
        erased_admin
      ]

      for org <- [site.id, tenant(), elsewhere.id],
          tiers <- [[:admin], [:editor], [:viewer], [:admin, :editor]] do
        roster = org |> Scoping.users_with_tier(tiers) |> MapSet.new(& &1.id)

        for person <- people do
          assert Scoping.has_tier?(org, person.id, tiers) == MapSet.member?(roster, person.id),
                 "has_tier? disagrees with users_with_tier for #{inspect(tiers)} on #{org}"
        end
      end

      # Not vacuous: both answers occur.
      assert Scoping.has_tier?(site.id, member_admin.id, [:admin])
      assert Scoping.has_tier?(site.id, platform_admin.id, [:admin])
      refute Scoping.has_tier?(site.id, pending_admin.id, [:admin])
      refute Scoping.has_tier?(site.id, erased_admin.id, [:admin])
      assert Scoping.has_tier?(tenant(), legacy_editor.id, [:editor])
      refute Scoping.has_tier?(tenant(), foreign_editor.id, [:editor])
    end
  end

  describe "mention_roster_member?/2 answers as mention_roster/1 does" do
    test "for every kind of account and org" do
      site = KilnCMS.OrgFixtures.org("entitled-roster")
      elsewhere = KilnCMS.OrgFixtures.org("entitled-roster-elsewhere")

      unscoped = user(:editor)
      member = user(:editor)
      membership!(member, site.id, :editor)
      pending = user(:editor)
      membership!(pending, site.id, :editor, :pending)
      foreign = user(:editor)
      membership!(foreign, elsewhere.id, :editor)
      muted = user(:editor, %{notify_on_comment: false})
      erased = user(:editor, %{anonymized_at: DateTime.utc_now()})
      # Removed from the only site they belonged to: removal deletes the row.
      removed = user(:editor)
      removed |> membership!(elsewhere.id, :editor) |> remove!()

      people = [unscoped, member, pending, foreign, muted, erased, removed]

      for org <- [site.id, elsewhere.id, tenant()] do
        roster = org |> Notifications.mention_roster() |> MapSet.new(& &1.id)

        for person <- people do
          assert Notifications.mention_roster_member?(org, person) ==
                   MapSet.member?(roster, person.id),
                 "mention_roster_member? disagrees with mention_roster on #{org}"
        end
      end

      assert Notifications.mention_roster_member?(site.id, member)
      assert Notifications.mention_roster_member?(site.id, unscoped)
      # A pending registration is not a member, and its row scopes the account.
      refute Notifications.mention_roster_member?(site.id, pending)
      refute Notifications.mention_roster_member?(tenant(), pending)
      refute Notifications.mention_roster_member?(site.id, foreign)
      refute Notifications.mention_roster_member?(site.id, muted)
      refute Notifications.mention_roster_member?(site.id, erased)

      # Pinned, not endorsed: with no membership row left, an account removed
      # from its only site reads as unscoped, so it is on every org's roster,
      # the site it was removed from included. A follow-up decides the rule.
      assert Notifications.mention_roster_member?(site.id, removed)
      assert Notifications.mention_roster_member?(elsewhere.id, removed)
    end
  end

  describe "legacy jobs, as v1.10.1 queued them" do
    defp legacy!(worker, args) do
      job = args |> worker.new() |> Oban.insert!()

      # As in `QueuedMailTest`: the column default is the sandbox
      # transaction's start, which would make every account look younger.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [inserted_at: DateTime.utc_now()]
      )

      job
    end

    defp legacy_workflow(to, event, attrs) do
      Map.merge(
        %{
          "to" => to,
          "event" => event,
          "kind" => "page",
          "title" => "Legacy #{unique()}",
          "id" => Ecto.UUID.generate(),
          "actor_name" => "Legacy Actor",
          "org_id" => tenant()
        },
        attrs
      )
    end

    defp legacy_assigned(to, task) do
      %{
        "kind" => "assigned",
        "to" => to,
        "task_id" => task.id,
        "content_type" => task.content_type,
        "content_id" => task.content_id,
        "block_id" => nil,
        "org_id" => tenant(),
        "due_on" => nil,
        "note" => "legacy note",
        "actor_name" => "Legacy Actor"
      }
    end

    defp legacy_digest(to, items) do
      %{"kind" => "digest", "to" => to, "org_id" => tenant(), "items" => items}
    end

    defp item(content_type, content_id) do
      %{
        "content_type" => content_type,
        "content_id" => content_id,
        "due_on" => Date.to_iso8601(Date.utc_today())
      }
    end

    test "a review request to an account no longer an admin is not sent" do
      demoted = user(:editor)
      still = user(:admin)
      legacy!(WorkflowMailWorker, legacy_workflow(address(demoted), "submitted_for_review", %{}))
      legacy!(WorkflowMailWorker, legacy_workflow(address(still), "submitted_for_review", %{}))
      drain()

      sent = emails()
      assert [_review] = to(sent, address(still))
      assert to(sent, address(demoted)) == []
    end

    test "a published notice goes to the content's author only" do
      author = user(:editor)
      other = user(:editor)
      page = page!(author)

      for person <- [author, other] do
        legacy!(
          WorkflowMailWorker,
          legacy_workflow(address(person), "published", %{"id" => page.id})
        )
      end

      drain()

      sent = emails()
      assert [_published] = to(sent, address(author))
      assert to(sent, address(other)) == []
    end

    test "a mention to someone off the roster is not sent" do
      off = user(:editor)
      membership!(off, tenant(), :editor, :pending)
      on = user(:editor)

      for person <- [off, on] do
        legacy!(WorkflowMailWorker, legacy_workflow(address(person), "comment_mention", %{}))
      end

      drain()

      sent = emails()
      assert [_mention] = to(sent, address(on))
      assert to(sent, address(off)) == []
    end

    # Documented in `WorkflowMailWorker`: its args cannot find the thread
    # reliably, so the release before's decision stands.
    test "a comment notice on a thread is sent unchecked" do
      bystander = user(:editor)

      legacy!(
        WorkflowMailWorker,
        legacy_workflow(address(bystander), "comment_added", %{
          "block_id" => Ecto.UUID.generate(),
          "excerpt" => "legacy excerpt"
        })
      )

      drain()

      assert [_comment] = to(emails(), address(bystander))
    end

    test "an assignment whose task was reassigned since is not sent" do
      first = user(:editor)
      second = user(:editor)
      moved = assign!(first)
      kept = assign!(second)
      drain()
      emails()

      CMS.update_task!(moved, %{assignee_id: user(:editor).id}, actor: user(:editor))
      legacy!(TaskMailWorker, legacy_assigned(address(first), moved))
      legacy!(TaskMailWorker, legacy_assigned(address(second), kept))
      drain()

      sent = emails()
      assert [_assigned] = to(sent, address(second))
      assert to(sent, address(first)) == []
    end

    test "a digest lists only lines on content where an open task of theirs still is" do
      assignee = user(:editor)
      task = assign!(assignee, %{due_on: Date.utc_today()})
      drain()
      emails()

      legacy!(
        TaskMailWorker,
        legacy_digest(address(assignee), [
          item(task.content_type, task.content_id),
          item("page", Ecto.UUID.generate())
        ])
      )

      drain()

      assert [digest] = to(emails(), address(assignee))
      assert digest.subject == "Your task digest: 1 item"
    end

    test "a digest line shows its task's due date now" do
      assignee = user(:editor)
      moved_to = Date.add(Date.utc_today(), 2)
      task = assign!(assignee, %{due_on: Date.utc_today()})
      CMS.update_task!(task, %{due_on: moved_to}, actor: user(:editor))
      drain()
      emails()

      legacy!(
        TaskMailWorker,
        legacy_digest(address(assignee), [item(task.content_type, task.content_id)])
      )

      drain()

      assert [digest] = to(emails(), address(assignee))
      assert digest.html_body =~ Date.to_iso8601(moved_to)
      refute digest.html_body =~ Date.to_iso8601(Date.utc_today())
    end

    test "a digest with no line left is not sent" do
      assignee = user(:editor)

      legacy!(
        TaskMailWorker,
        legacy_digest(address(assignee), [item("page", Ecto.UUID.generate())])
      )

      drain()

      assert to(emails(), address(assignee)) == []
    end

    test "a suppressed address is not sent either shape" do
      admin = user(:admin)
      assignee = user(:editor)
      task = assign!(assignee)
      drain()
      emails()

      suppress!(address(admin))
      suppress!(address(assignee))
      legacy!(WorkflowMailWorker, legacy_workflow(address(admin), "submitted_for_review", %{}))
      legacy!(TaskMailWorker, legacy_assigned(address(assignee), task))
      drain()

      sent = emails()
      assert to(sent, address(admin)) == []
      assert to(sent, address(assignee)) == []
    end
  end
end
