defmodule KilnCMS.CMS.BookkeepingAuthorizationTest do
  @moduledoc """
  What the CMS's own bookkeeping is *authorized* to do, now that the changes
  behind a publish, a rename, a content write and a form submission run as
  `KilnCMS.CMS.Bookkeeping.system/0` instead of `authorize?: false` (#1659),
  and that the reads those changes decide on fail CLOSED when the grant is
  gone.

  Every grant has a refusal next to it: the system completes a task but cannot
  edit or reopen one; it points `published_version_id` but cannot `:update` a
  page; it writes a slug's 301 but an editor still cannot write a redirect by
  hand; it reads the spam keywords but cannot save them.

  The fail-closed tests take the grant away with `Bookkeeping.with_actor(nil,
  …)` and assert on what a *filtered* read could not produce — a refused
  write, a raise, the stored values intact — never on `{:ok, _}`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Bookkeeping
  alias KilnCMS.CMS.Page
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Bookkeeping.system()
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cbk-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp reload(page), do: Ash.get!(Page, page.id, authorize?: false)

  test "Bookkeeping.system/0 is a system actor labelled :cms_bookkeeping" do
    assert %SystemActor{subsystem: :cms_bookkeeping} = Bookkeeping.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Bookkeeping.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :cms_bookkeeping} = Bookkeeping.system()
    assert Bookkeeping.with_actor(nil, &Bookkeeping.system/0) == nil
  end

  describe "Task — completed by a publish" do
    setup do
      editor = user(:editor)
      page = CMS.create_page!(%{title: "Tasks", slug: "cbk-t-#{uniq()}"}, actor: editor)

      task =
        CMS.assign_task!(
          %{content_type: "page", content_id: page.id, assignee_id: editor.id},
          actor: editor
        )

      %{editor: editor, page: page, task: task}
    end

    test "the system may complete a task", %{task: task} do
      assert {:ok, %{status: :done, completed_by_id: nil}} =
               CMS.complete_task(task, %{}, actor: system(), tenant: org_id())
    end

    test "the system may not edit, reassign or reopen one", %{task: task, editor: editor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_task(task, %{note: "hijacked"}, actor: system(), tenant: org_id())

      done = CMS.complete_task!(task, %{}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.reopen_task(done, %{}, actor: system(), tenant: org_id())
    end

    test "a publish completes the open task through the grant", %{page: page, task: task} do
      CMS.publish_page!(page, %{}, actor: user(:admin))
      assert CMS.get_task!(task.id, authorize?: false).status == :done
    end

    test "with the grant gone the publish FAILS rather than leaving the task open",
         %{page: page, task: task} do
      admin = user(:admin)

      assert_raise Ash.Error.Forbidden, fn ->
        Bookkeeping.with_actor(nil, fn -> CMS.publish_page(page, %{}, actor: admin) end)
      end

      assert CMS.get_task!(task.id, authorize?: false).status == :open
      assert reload(page).state == :draft
    end
  end

  describe "content — :set_published_version_id" do
    setup do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Pointer", slug: "cbk-p-#{uniq()}"}, actor: admin)
      %{admin: admin, page: CMS.publish_page!(page, %{}, actor: admin)}
    end

    test "a publish points the record at its version", %{page: page} do
      refute is_nil(reload(page).published_version_id)
    end

    test "the system may set the pointer", %{page: page} do
      assert {:ok, %{published_version_id: nil}} =
               Ash.update(page, %{published_version_id: nil},
                 action: :set_published_version_id,
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "the system may not edit the page itself", %{page: page} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_page(page, %{title: "hijacked"}, actor: system(), tenant: org_id())
    end

    test "with the grant gone an unpublish fails rather than leave a dangling pointer",
         %{page: page, admin: admin} do
      assert {:error, _} =
               Bookkeeping.with_actor(nil, fn -> CMS.unpublish_page(page, %{}, actor: admin) end)

      reloaded = reload(page)
      assert reloaded.state == :published
      refute is_nil(reloaded.published_version_id)

      assert {:ok, %{published_version_id: nil}} = CMS.unpublish_page(page, %{}, actor: admin)
    end
  end

  describe "Redirect — a published rename's 301" do
    setup do
      editor = user(:editor)
      page = Ash.Seed.seed!(Page, %{title: "Moving", slug: "cbk-r-#{uniq()}", state: :published})
      %{editor: editor, page: page}
    end

    defp redirects_at(path) do
      CMS.list_redirects!(tenant: org_id(), query: [filter: [path: path]])
    end

    test "an EDITOR's rename leaves the 301 and retires a redirect squatting on the new path",
         %{editor: editor, page: page} do
      new_slug = "cbk-r-new-#{uniq()}"
      other = Ash.Seed.seed!(Page, %{title: "O", slug: "cbk-o-#{uniq()}", state: :published})

      CMS.create_redirect!(
        %{path: "/#{new_slug}", locale: "en", target_type: "page", target_id: other.id},
        authorize?: false,
        tenant: org_id()
      )

      assert {:ok, _} = CMS.update_page(page, %{slug: new_slug}, actor: editor)

      assert [%{target_id: target}] = redirects_at("/#{page.slug}")
      assert target == page.id
      assert redirects_at("/#{new_slug}") == []
    end

    test "with the grant gone the rename fails — a published URL is never vacated without its 301",
         %{editor: editor, page: page} do
      assert_raise Ash.Error.Forbidden, fn ->
        Bookkeeping.with_actor(nil, fn ->
          CMS.update_page(page, %{slug: "cbk-r-lost-#{uniq()}"}, actor: editor)
        end)
      end

      assert reload(page).slug == page.slug
      assert redirects_at("/#{page.slug}") == []
    end

    test "the system may create and destroy a redirect; an editor may not create one",
         %{editor: editor, page: page} do
      attrs = %{
        path: "/cbk-hand-#{uniq()}",
        locale: "en",
        target_type: "page",
        target_id: page.id
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_redirect(attrs, actor: editor, tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_redirect(attrs, actor: nil, tenant: org_id())

      assert {:ok, redirect} = CMS.create_redirect(attrs, actor: system(), tenant: org_id())
      assert :ok = CMS.destroy_redirect(redirect, actor: system(), tenant: org_id())
      assert redirects_at(attrs.path) == []
    end
  end

  describe "ReleaseItem — freed when an unshipped release is archived" do
    setup do
      editor = user(:editor)
      page = CMS.create_page!(%{title: "Held", slug: "cbk-rel-#{uniq()}"}, actor: editor)
      release = CMS.create_release!(%{name: "Held #{uniq()}"}, actor: editor)

      item =
        CMS.add_release_item!(
          %{release_id: release.id, content_type: "page", content_id: page.id, action: :publish},
          actor: editor
        )

      %{editor: editor, release: release, item: item}
    end

    defp item_status(item),
      do: Ash.get!(KilnCMS.CMS.ReleaseItem, item.id, authorize?: false).status

    test "an EDITOR's archive cancels the pending item through the grant",
         %{editor: editor, release: release, item: item} do
      assert {:ok, %{state: :archived}} = CMS.archive_release(release, %{}, actor: editor)
      assert item_status(item) == :cancelled
    end

    test "the system may mark an item cancelled; the editor may not reach a mark_* write",
         %{editor: editor, item: item} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.mark_release_item_cancelled(item, %{}, actor: editor)

      assert {:ok, %{status: :cancelled}} =
               CMS.mark_release_item_cancelled(item, %{}, actor: system(), tenant: org_id())
    end

    test "with the grant gone the archive fails and the item keeps its reservation",
         %{editor: editor, release: release, item: item} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Bookkeeping.with_actor(nil, fn ->
                 CMS.archive_release(release, %{}, actor: editor)
               end)

      assert item_status(item) == :pending
    end
  end

  describe "FormSpamSettings — the submission scorer" do
    setup do
      admin = user(:admin)
      CMS.save_form_spam_settings!(%{keywords: ["casino"]}, actor: admin)
      form = CMS.create_form!(%{name: "Contact", slug: "cbk-f-#{uniq()}"}, actor: admin)
      %{admin: admin, form: form}
    end

    defp submit(form, message) do
      CMS.create_form_submission(%{form_id: form.id, data: %{"message" => message}},
        authorize?: false,
        tenant: org_id()
      )
    end

    test "the system reads the keyword list, and the scorer uses it", %{form: form} do
      assert [%{keywords: ["casino"]}] =
               CMS.list_form_spam_settings!(actor: system(), tenant: org_id())

      {:ok, clean} = submit(form, "hello there")
      {:ok, hit} = submit(form, "win at the casino")
      assert hit.spam_score > clean.spam_score
    end

    test "the system may not save the keyword list" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_form_spam_settings(%{keywords: []}, actor: system(), tenant: org_id())
    end

    test "with the grant gone a submission is refused, not stored unscored", %{form: form} do
      assert_raise Ash.Error.Forbidden, fn ->
        Bookkeeping.with_actor(nil, fn -> submit(form, "win at the casino") end)
      end

      assert CMS.recent_form_submissions!(form.id, authorize?: false, tenant: org_id()) == []
    end
  end

  describe "FieldDefinition — the custom-field registry every content write reads" do
    setup do
      admin = user(:admin)
      name = "cbk_#{uniq()}"

      CMS.create_field_definition!(%{content_type: :page, name: name, label: "Kept"},
        actor: admin
      )

      page =
        CMS.create_page!(
          %{title: "Fields", slug: "cbk-cf-#{uniq()}", custom_fields: %{name => "keep me"}},
          actor: admin
        )

      %{admin: admin, page: page, name: name}
    end

    test "an update keeps the stored value through the grant",
         %{admin: admin, page: page, name: name} do
      updated = CMS.update_page!(page, %{title: "Renamed"}, actor: admin)
      assert updated.custom_fields[name] == "keep me"
    end

    # A partial write: `%{}` names no key, so under the merge every stored key
    # is carried forward from the definitions. A refused read filtering to
    # "no definitions" would carry nothing forward and store `%{}` — silently.
    test "with the grant gone a partial custom-field write raises instead of wiping the values",
         %{admin: admin, page: page, name: name} do
      assert_raise Ash.Error.Forbidden, fn ->
        Bookkeeping.with_actor(nil, fn ->
          CMS.update_page!(page, %{custom_fields: %{}}, actor: admin)
        end)
      end

      assert reload(page).custom_fields[name] == "keep me"
    end

    # The computed-field refresh reads the registry on EVERY update.
    test "with the grant gone even a title edit raises rather than skip the registry",
         %{admin: admin, page: page} do
      assert_raise Ash.Error.Forbidden, fn ->
        Bookkeeping.with_actor(nil, fn -> CMS.update_page!(page, %{title: "T2"}, actor: admin) end)
      end

      assert reload(page).title == "Fields"
    end
  end
end
