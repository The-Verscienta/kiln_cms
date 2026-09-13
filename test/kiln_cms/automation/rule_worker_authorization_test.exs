defmodule KilnCMS.Automation.RuleWorkerAuthorizationTest do
  @moduledoc """
  What an editorial automation reaction is *authorized* to do, now that
  `KilnCMS.Automation.RuleWorker` runs as
  `%KilnCMS.SystemActor{subsystem: :automation}` instead of
  `authorize?: false` (#1402).

  The shape of the grant is the point, so the negatives carry as much weight as
  the positives: automation **reads** a rule and the site's social accounts but
  cannot author either, and it **opens** comments and tasks but cannot update
  them. Removing any `KilnCMS.Checks.SystemActor` clause from those four
  resources must turn a test here red.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Automation
  alias KilnCMS.CMS
  alias KilnCMS.Social
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])

  defp org_id, do: Accounts.default_org_id()

  defp system, do: SystemActor.new(:automation)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rwa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp page do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: "Reviewed",
      slug: "rwa-#{uniq()}",
      locale: "en",
      state: :published
    })
  end

  defp social_account do
    Ash.Seed.seed!(Social.Account, %{
      org_id: org_id(),
      provider: :mastodon,
      handle: "@rwa-#{uniq()}@example.social",
      instance_url: "https://example.social",
      enabled: true
    })
  end

  defp rule do
    Ash.Seed.seed!(Automation.Rule, %{
      org_id: org_id(),
      name: "Rule #{uniq()}",
      trigger_event: :published,
      action: :broadcast,
      config: %{},
      enabled: true
    })
  end

  describe "Automation.Rule — read, and only read" do
    test "the worker re-reads the rule it was enqueued for" do
      rule = rule()

      assert {:ok, %{id: id}} =
               Automation.get_rule(rule.id, actor: system(), tenant: org_id())

      assert id == rule.id
    end

    test "it cannot author one" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Automation.create_rule(
                 %{name: "Nope", trigger_event: :published, action: :broadcast, config: %{}},
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "it cannot disable one either" do
      rule = rule()

      assert {:error, %Ash.Error.Forbidden{}} =
               Automation.update_rule(rule, %{enabled: false}, actor: system(), tenant: org_id())
    end
  end

  describe "Social.Account — read, and only read" do
    test "the announcer may list a provider's accounts but not mint one" do
      # Asserting on the ROW, not on `{:ok, _}`: this is a filter policy, so a
      # refused read comes back `{:ok, []}` and a shape-only assertion would
      # pass with the system clause removed.
      account = social_account()

      ids =
        :mastodon
        |> Social.accounts_for_provider!(actor: system(), tenant: org_id())
        |> Enum.map(& &1.id)

      assert account.id in ids

      # And it is admin-or-system: an editor is filtered to nothing.
      assert Social.accounts_for_provider!(:mastodon, actor: user(:editor), tenant: org_id()) ==
               []

      assert {:error, %Ash.Error.Forbidden{}} =
               Social.create_account(
                 %{
                   provider: :mastodon,
                   handle: "@site@example.social",
                   instance_url: "https://example.social",
                   credential: "secret",
                   enabled: true
                 },
                 actor: system(),
                 tenant: org_id()
               )
    end
  end

  describe "CMS.Comment — automation posts, it does not edit" do
    test "a document-level finding lands as a comment with rule provenance" do
      document = page()
      rule = rule()

      assert {:ok, comment} =
               CMS.add_comment(
                 %{
                   content_type: "page",
                   content_id: document.id,
                   block_id: nil,
                   body: "Three headings skip a level.",
                   created_by_rule_id: rule.id
                 },
                 actor: system(),
                 tenant: org_id()
               )

      # No `author_id`: the actor has no `:id`, deliberately — the rule id is
      # the provenance instead.
      assert is_nil(comment.author_id)
      assert comment.created_by_rule_id == rule.id
    end

    test "it may not resolve a comment anyone left" do
      document = page()
      editor = user(:editor)

      {:ok, comment} =
        CMS.add_comment(
          %{
            content_type: "page",
            content_id: document.id,
            block_id: Ash.UUID.generate(),
            body: "Mine."
          },
          actor: editor,
          tenant: org_id()
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.resolve_comment(comment, actor: system(), tenant: org_id())
    end
  end

  describe "CMS.Task — automation opens, it does not close" do
    test "findings land as a task, and the assignee is still vetted" do
      document = page()
      editor = user(:editor)
      rule = rule()

      assert {:ok, task} =
               CMS.assign_task(
                 %{
                   content_type: "page",
                   content_id: document.id,
                   assignee_id: editor.id,
                   due_on: Date.add(Date.utc_today(), 3),
                   note: "Two links are dead.",
                   created_by_rule_id: rule.id,
                   kind: :intelligence_finding
                 },
                 actor: system(),
                 tenant: org_id()
               )

      assert is_nil(task.creator_id)
      assert task.created_by_rule_id == rule.id

      # `AssigneeIsEditor` runs whatever the actor is — a viewer is refused.
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.assign_task(
                 %{
                   content_type: "page",
                   content_id: document.id,
                   assignee_id: user(:viewer).id,
                   due_on: Date.add(Date.utc_today(), 3),
                   note: "Nope.",
                   created_by_rule_id: rule.id,
                   kind: :intelligence_finding
                 },
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "the lifecycle probe reads open tasks" do
      document = page()
      editor = user(:editor)

      {:ok, _task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: document.id,
            assignee_id: editor.id,
            due_on: Date.add(Date.utc_today(), 3),
            kind: :lifecycle_review
          },
          actor: editor,
          tenant: org_id()
        )

      assert [%{kind: :lifecycle_review}] =
               CMS.list_open_tasks_of_kind!("page", document.id, :lifecycle_review,
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "it may not complete anyone's task" do
      document = page()
      editor = user(:editor)

      {:ok, task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: document.id,
            assignee_id: editor.id,
            due_on: Date.add(Date.utc_today(), 3)
          },
          actor: editor,
          tenant: org_id()
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.complete_task(task, actor: system(), tenant: org_id())
    end
  end

  describe "what the automation actor deliberately cannot do" do
    test "it reads no content and no accounts" do
      draft =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Unpublished",
          slug: "rwa-draft-#{uniq()}",
          locale: "en",
          state: :draft
        })

      assert {:ok, []} =
               KilnCMS.CMS.Page
               |> Ash.Query.filter(id == ^draft.id)
               |> Ash.read(actor: system(), tenant: org_id())

      # `Accounts.User`'s read policy is self-only and stays that way — the
      # worker's `editor?/2` lookup keeps its bypass for exactly this reason.
      assert {:ok, []} = Ash.read(KilnCMS.Accounts.User, actor: system())
    end
  end
end
