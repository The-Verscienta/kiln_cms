defmodule KilnCMS.Notifications.BlockTaskEmailTest do
  @moduledoc """
  What an assignment email says when the task names a block.

  The interesting part is what it deliberately does **not** say: the block's
  content. Block fields can sit behind `editable_by` grants
  (`Changes.EnforceBlockFieldPolicy`), and an email has no actor to check them
  against — so the email names the block's *type* (read through the id-only
  `block_ids` projection) and links to it, rather than quoting the paragraph.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "blocktaskmail-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp sent_emails do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.filter(&String.contains?(&1.subject, "Task assigned"))
  end

  defp page(actor) do
    CMS.create_page!(
      %{
        title: "Email spec",
        slug: "blocktaskmail-#{System.unique_integer([:positive])}",
        blocks: [%{"_type" => "quote", "text" => "Quoted words that must not be emailed"}]
      },
      actor: actor
    )
  end

  defp block_id(page), do: page.blocks |> hd() |> Map.fetch!(:value) |> Map.fetch!(:id)

  test "a block task's email names the block's type and deep-links to its discussion" do
    editor = user(:editor)
    assignee = user(:editor)
    target = page(editor)

    {:ok, _task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: block_id(target),
          assignee_id: assignee.id
        },
        actor: editor
      )

    drain()

    assert [email] = sent_emails()
    assert email.html_body =~ "On the quote block."
    assert email.html_body =~ "comment=#{block_id(target)}"
    assert email.html_body =~ "Open that block in the editor"

    # The block's own words stay in the editor, where a policy can be applied
    # to them.
    refute email.html_body =~ "Quoted words that must not be emailed"
  end

  test "a document-level task's email is unchanged — no block line, no block link" do
    editor = user(:editor)
    assignee = user(:editor)
    target = page(editor)

    {:ok, _task} =
      CMS.assign_task(
        %{content_type: "page", content_id: target.id, assignee_id: assignee.id},
        actor: editor
      )

    drain()

    assert [email] = sent_emails()
    refute email.html_body =~ "On the"
    refute email.html_body =~ "comment="
    assert email.html_body =~ "Open it in the editor"
  end

  # The task outlives its block, so the email has to as well — dropping the
  # line would imply the task is about the whole document.
  test "a task whose block was deleted says the block is gone" do
    editor = user(:editor)
    assignee = user(:editor)
    target = page(editor)
    doomed = block_id(target)

    CMS.update_page!(target, %{blocks: []}, actor: editor)

    {:ok, _task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: doomed,
          assignee_id: assignee.id
        },
        actor: editor
      )

    drain()

    assert [email] = sent_emails()
    assert email.html_body =~ "On a block that has since been removed."
  end

  test "the task.assigned webhook payload carries the block" do
    editor = user(:editor)
    assignee = user(:editor)
    target = page(editor)

    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["task.assigned"]},
      actor: user(:admin)
    )

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: block_id(target),
          assignee_id: assignee.id
        },
        actor: editor
      )

    assert [delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
    assert delivery.event == "task.assigned"
    assert delivery.payload["block_id"] == task.block_id
    drain()
  end
end
