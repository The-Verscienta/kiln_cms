defmodule KilnCMS.NotificationsTest do
  @moduledoc """
  Content-workflow events send notification emails (via Oban): submitting for
  review notifies admins; publishing notifies the author.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role, prefs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "notif-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        prefs
      )
    )
  end

  defp slug, do: "notif-#{System.unique_integer([:positive])}"

  defp drain, do: KilnCMS.DataCase.drain_oban()

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

  defp local_part(user), do: user.email |> to_string() |> String.split("@") |> hd()

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

  test "returning to draft emails the author" do
    admin = user(:admin)
    editor = user(:editor)

    page = CMS.create_page!(%{title: "Needs Work", slug: slug()}, actor: editor)
    page = CMS.submit_page_for_review!(page, %{}, actor: editor)
    CMS.return_page_to_draft!(page, %{}, actor: admin)
    drain()

    returned = sent_emails("Needs Work") |> Enum.filter(&(&1.subject =~ "Changes requested"))
    assert [email] = returned
    assert email.subject == "Changes requested: Needs Work"
    assert recipients(email) == [to_string(editor.email)]
  end

  test "review email shows the submitter's display name, not their email (#214)" do
    _admin = user(:admin)
    editor = user(:editor, %{name: "Jane Smith"})

    page = CMS.create_page!(%{title: "Bylined", slug: slug()}, actor: editor)
    CMS.submit_page_for_review!(page, %{}, actor: editor)
    drain()

    assert [review] = sent_emails("Bylined")
    assert review.html_body =~ "Jane Smith"
    refute review.html_body =~ local_part(editor)
  end

  test "review email falls back to a neutral name when none is set (#214)" do
    _admin = user(:admin)
    editor = user(:editor)

    page = CMS.create_page!(%{title: "Anon Submit", slug: slug()}, actor: editor)
    CMS.submit_page_for_review!(page, %{}, actor: editor)
    drain()

    assert [review] = sent_emails("Anon Submit")
    assert review.html_body =~ "An editor"
    refute review.html_body =~ local_part(editor)
  end

  test "an admin who opted out of review-request emails is skipped" do
    opted_out = user(:admin, %{notify_on_review_request: false})
    opted_in = user(:admin)
    editor = user(:editor)

    page = CMS.create_page!(%{title: "Muted Review", slug: slug()}, actor: editor)
    CMS.submit_page_for_review!(page, %{}, actor: editor)
    drain()

    assert [review] = sent_emails("Muted Review")
    assert recipients(review) == [to_string(opted_in.email)]
    refute to_string(opted_out.email) in recipients(review)
  end

  test "an author who opted out of publish emails is not notified" do
    admin = user(:admin)
    editor = user(:editor, %{notify_on_publish: false})

    page = CMS.create_page!(%{title: "Quiet Launch", slug: slug()}, actor: editor)
    CMS.publish_page!(page, %{}, actor: admin)
    drain()

    assert sent_emails("Quiet Launch") == []
  end

  test "an author who opted out of return-to-draft emails is not notified" do
    admin = user(:admin)
    editor = user(:editor, %{notify_on_return_to_draft: false})

    page = CMS.create_page!(%{title: "Silent Revisions", slug: slug()}, actor: editor)
    page = CMS.submit_page_for_review!(page, %{}, actor: editor)
    CMS.return_page_to_draft!(page, %{}, actor: admin)
    drain()

    # The submit-for-review email to the admin still goes out; only the
    # author's "Changes requested" notification is suppressed.
    refute Enum.any?(sent_emails("Silent Revisions"), &(&1.subject =~ "Changes requested"))
  end
end
