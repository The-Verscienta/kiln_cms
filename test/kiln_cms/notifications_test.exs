defmodule KilnCMS.NotificationsTest do
  @moduledoc """
  Content-workflow events send notification emails (via Oban): submitting for
  review notifies admins; publishing notifies the author.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "notif-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "notif-#{System.unique_integer([:positive])}"

  defp drain, do: Oban.drain_queue(queue: :default, with_recursion: true)

  # Swoosh's test adapter delivers `{:email, email}` to this process; collect
  # every one currently in the mailbox (order-independent assertions). Each test
  # uses a unique content title and filters on it, so concurrently-running
  # suites' emails (the mailbox is process-global under shared sandbox mode)
  # don't leak into the assertion.
  defp sent_emails(title_match) do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.filter(&String.contains?(&1.subject, title_match))
  end

  defp recipients(email), do: Enum.map(email.to, fn {_name, addr} -> addr end)

  test "submitting for review emails admins, not the submitter" do
    admin = user(:admin)
    editor = user(:editor)

    page = CMS.create_page!(%{title: "My Draft", slug: slug()}, actor: editor)
    CMS.submit_page_for_review!(page, %{}, actor: editor)
    drain()

    emails = sent_emails("My Draft")

    assert [review] = emails
    assert review.subject == "Review requested: My Draft"
    assert recipients(review) == [to_string(admin.email)]
    refute to_string(editor.email) in recipients(review)
  end

  test "publishing emails the author, not the publisher" do
    admin = user(:admin)
    editor = user(:editor)

    page = CMS.create_page!(%{title: "Big News", slug: slug()}, actor: editor)
    CMS.publish_page!(page, %{}, actor: admin)
    drain()

    assert [published] = sent_emails("Big News")
    assert published.subject == "Published: Big News"
    assert recipients(published) == [to_string(editor.email)]
    refute to_string(admin.email) in recipients(published)
  end

  test "posts notify on the same events" do
    admin = user(:admin)
    editor = user(:editor)

    post = CMS.create_post!(%{title: "Hello", slug: slug()}, actor: editor)
    post = CMS.submit_post_for_review!(post, %{}, actor: editor)
    CMS.publish_post!(post, %{}, actor: admin)
    drain()

    subjects = sent_emails("Hello") |> Enum.map(& &1.subject) |> Enum.sort()
    assert subjects == ["Published: Hello", "Review requested: Hello"]
  end

  test "publishing content with no author sends nothing" do
    # Seeded/system content created without an actor has no author to notify.
    page = CMS.create_page!(%{title: "Orphan", slug: slug()}, authorize?: false)
    CMS.publish_page!(page, %{}, authorize?: false)
    drain()

    assert sent_emails("Orphan") == []
  end
end
