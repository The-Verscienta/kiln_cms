defmodule KilnCMS.CMS.TaskAutoCompleteTest do
  @moduledoc """
  The org default and the per-task override for auto-complete-on-publish
  (#818).

  #501 shipped this unconditional. The behaviour under test is the precedence:
  a task's own `auto_complete_on_publish` wins when set, the site's
  `SiteEditorialSettings` answers when it isn't, and `true` answers when
  neither exists — which is what keeps an existing install's behaviour
  unchanged after this migration.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Task
  alias KilnCMS.CMS.TaskSettings

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "autocomplete-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "auto-#{System.unique_integer([:positive])}"

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp page_with_task(editor, task_attrs \\ %{}) do
    page = CMS.create_page!(%{title: "Task fixture", slug: slug()}, actor: editor)

    {:ok, task} =
      CMS.assign_task(
        Map.merge(
          %{content_type: "page", content_id: page.id, assignee_id: editor.id},
          task_attrs
        ),
        actor: editor
      )

    {page, task}
  end

  defp status_after_publish(page, task, admin) do
    CMS.publish_page!(page, %{}, actor: admin)
    drain()
    CMS.get_task!(task.id, authorize?: false).status
  end

  defp set_site_default(admin, value) do
    {:ok, _settings} =
      CMS.save_site_editorial_settings(%{auto_complete_tasks_on_publish: value}, actor: admin)

    :ok
  end

  describe "with no settings row (a fresh or upgraded install)" do
    # The compatibility guarantee: the migration adds a NULLABLE column with no
    # default, so every existing task is `nil`, and no site has a settings row.
    # Both resolve to the #501 behaviour.
    test "publishing still completes an open task" do
      editor = user(:editor)
      admin = user(:admin)
      {page, task} = page_with_task(editor)

      assert status_after_publish(page, task, admin) == :done
    end

    test "site_default/1 answers true without writing a row" do
      admin = user(:admin)
      org = KilnCMS.Accounts.default_org_id()

      assert TaskSettings.site_default(org) == true
      # Reading must not create the row — a task list should not be a write.
      assert CMS.list_site_editorial_settings!(actor: admin) == []
    end
  end

  describe "the site default" do
    test "off means an open task survives the publish" do
      editor = user(:editor)
      admin = user(:admin)
      set_site_default(admin, false)

      {page, task} = page_with_task(editor)

      assert status_after_publish(page, task, admin) == :open
    end

    test "back on restores completion, including for tasks assigned while it was off" do
      editor = user(:editor)
      admin = user(:admin)
      set_site_default(admin, false)

      {page, task} = page_with_task(editor)

      # The task carries no override, so it follows the site — flipping the
      # setting moves it, which is the whole point of `nil` meaning "inherit"
      # rather than being resolved to a value at assign time.
      set_site_default(admin, true)

      assert status_after_publish(page, task, admin) == :done
    end

    test "saving is upsert, so a second save does not create a second row" do
      admin = user(:admin)

      set_site_default(admin, false)
      set_site_default(admin, true)

      assert [%{auto_complete_tasks_on_publish: true}] =
               CMS.list_site_editorial_settings!(actor: admin)
    end
  end

  describe "the per-task override" do
    test "false keeps a task open even when the site completes" do
      editor = user(:editor)
      admin = user(:admin)
      {page, task} = page_with_task(editor, %{auto_complete_on_publish: false})

      assert status_after_publish(page, task, admin) == :open
    end

    test "true completes a task even when the site does not" do
      editor = user(:editor)
      admin = user(:admin)
      set_site_default(admin, false)

      {page, task} = page_with_task(editor, %{auto_complete_on_publish: true})

      assert status_after_publish(page, task, admin) == :done
    end

    # The mixed case is the reason this design exists rather than either half
    # alone: one follow-up task outliving the publish, everything else closing.
    test "only the opted-out task survives a publish that closes its siblings" do
      editor = user(:editor)
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Mixed", slug: slug()}, actor: editor)

      assign = fn attrs ->
        {:ok, task} =
          CMS.assign_task(
            Map.merge(
              %{content_type: "page", content_id: page.id, assignee_id: editor.id},
              attrs
            ),
            actor: editor
          )

        task
      end

      review = assign.(%{note: "review"})
      follow_up = assign.(%{note: "follow-up", auto_complete_on_publish: false})

      CMS.publish_page!(page, %{}, actor: admin)
      drain()

      assert CMS.get_task!(review.id, authorize?: false).status == :done
      assert CMS.get_task!(follow_up.id, authorize?: false).status == :open
    end

    test "can be changed after assignment" do
      editor = user(:editor)
      admin = user(:admin)
      {page, task} = page_with_task(editor)

      {:ok, task} = CMS.update_task(task, %{auto_complete_on_publish: false}, actor: editor)
      assert task.auto_complete_on_publish == false

      assert status_after_publish(page, task, admin) == :open
    end
  end

  describe "precedence" do
    test "auto_complete?/2 prefers the task over the site" do
      assert TaskSettings.auto_complete?(%Task{auto_complete_on_publish: false}, true) == false
      assert TaskSettings.auto_complete?(%Task{auto_complete_on_publish: true}, false) == true
    end

    test "auto_complete?/2 falls through to the site when the task says nothing" do
      assert TaskSettings.auto_complete?(%Task{auto_complete_on_publish: nil}, true) == true
      assert TaskSettings.auto_complete?(%Task{auto_complete_on_publish: nil}, false) == false
    end

    # `describe/2` exists so a UI can say *why* — "off" and "off because the
    # site is set that way" are different things to an editor.
    test "describe/2 names which half decided" do
      assert TaskSettings.describe(%Task{auto_complete_on_publish: nil}, true) == {true, :site}
      assert TaskSettings.describe(%Task{auto_complete_on_publish: false}, true) == {false, :task}
    end
  end

  describe "the site default is resolved before the transaction" do
    # The regression this guards is subtle and severe. Reading the settings row
    # from the `after_action` hook puts the SELECT inside the publish
    # transaction, where a failure does not return `{:error, _}` — it raises
    # AND aborts the transaction, so `TaskSettings`' degrade-to-true branch
    # never runs and the publish itself fails. Publishing had no dependency on
    # this table before #818 and must not acquire one.
    test "a publish carries the resolved default in its changeset context" do
      editor = user(:editor)
      admin = user(:admin)
      set_site_default(admin, false)

      {page, task} = page_with_task(editor)

      # An explicit context wins over the read, which is what `Releases` uses to
      # turn one read per item into one per release. If the change resolved the
      # default inside the hook instead, this override could not reach it.
      CMS.publish_page!(page, %{}, actor: admin, context: %{auto_complete_default: true})
      drain()

      assert CMS.get_task!(task.id, authorize?: false).status == :done
    end

    test "a release go-live resolves it once and applies it to every item" do
      editor = user(:editor)
      admin = user(:admin)
      set_site_default(admin, false)

      {page, task} = page_with_task(editor)

      {:ok, release} =
        CMS.create_release(%{name: "Batch #{System.unique_integer([:positive])}"}, actor: admin)

      {:ok, _item} =
        CMS.add_release_item(
          %{
            release_id: release.id,
            content_type: "page",
            content_id: page.id,
            action: :publish
          },
          actor: admin
        )

      # Claim + run, the way the console's "Publish now" does.
      {:ok, _claimed} = CMS.start_release(release, %{}, actor: admin)
      drain()

      # Site default is off, task inherits — so it must survive the release too.
      assert CMS.get_task!(task.id, authorize?: false).status == :open
    end
  end

  describe "authorization" do
    test "an editor may read the setting but not change it" do
      editor = user(:editor)
      admin = user(:admin)
      set_site_default(admin, false)

      # Reading is editor-wide: the task rows explain what publishing will do,
      # and that sentence needs the setting.
      assert [%{auto_complete_tasks_on_publish: false}] =
               CMS.list_site_editorial_settings!(actor: editor)

      assert {:error, _} =
               CMS.save_site_editorial_settings(
                 %{auto_complete_tasks_on_publish: true},
                 actor: editor
               )
    end
  end
end
