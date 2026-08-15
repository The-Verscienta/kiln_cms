defmodule KilnCMS.CMS.CommentNotificationTest do
  @moduledoc """
  Editorial comments send notification emails (#801).

  The issue's acceptance criteria, one test each: a reply notifies the thread's
  other participants, resolving notifies them too, and an `@name` notifies that
  specific person. Plus the two rules the design rests on — you are never
  emailed about your own comment, and a mention replaces the thread email for
  that person rather than adding a second one.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  # Names are made unique per test. `KilnCMS.CMS.Mentions` deliberately resolves
  # an ambiguous handle to NOBODY, and the sandbox is shared, so two tests both
  # seeding a "Bob Jones" would make every `@bobjones` in the run ambiguous —
  # the feature behaving correctly, read as a failure.
  defp user(name, prefs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "cmt-#{System.unique_integer([:positive])}@example.com",
          name: "#{name} #{System.unique_integer([:positive])}",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        },
        prefs
      )
    )
  end

  # The handle that finds this user: their name with everything but letters and
  # digits removed, matching `Mentions.normalise/1`.
  defp handle(user), do: "@" <> String.replace(String.downcase(user.name), ~r/[^a-z0-9]/, "")

  defp a_page(author, title) do
    CMS.create_page!(
      %{
        title: title,
        slug: "cmt-#{System.unique_integer([:positive])}",
        blocks: [%{type: :heading, content: "Body", data: %{"level" => 2}, order: 0}]
      },
      actor: author
    )
  end

  defp block_id(page) do
    page = CMS.get_page!(page.id, authorize?: false)
    page.blocks |> hd() |> Map.get(:value) |> Map.get(:id)
  end

  defp comment!(page, block, body, actor) do
    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: block, body: body},
      actor: actor
    )
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

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

  defp recipients(emails) do
    emails |> Enum.flat_map(& &1.to) |> Enum.map(fn {_name, addr} -> addr end) |> Enum.sort()
  end

  defp address(user), do: user.email |> to_string()

  test "a reply notifies the thread's other participants, not its author" do
    alice = user("Alice Smith")
    bob = user("Bob Jones")
    title = "Thread #{System.unique_integer([:positive])}"
    page = a_page(alice, title)
    block = block_id(page)

    comment!(page, block, "First thought", bob)
    drain()
    _ = sent_emails(title)

    comment!(page, block, "Second thought", alice)
    drain()

    emails = sent_emails(title)

    # Bob is on the thread and hears about Alice's reply; Alice wrote it.
    assert address(bob) in recipients(emails)
    refute address(alice) in recipients(emails)
  end

  test "the content's author hears about a comment on their page" do
    alice = user("Alice Smith")
    bob = user("Bob Jones")
    title = "Authored #{System.unique_integer([:positive])}"
    page = a_page(alice, title)

    comment!(page, block_id(page), "Needs work", bob)
    drain()

    assert address(alice) in recipients(sent_emails(title))
  end

  test "resolving a thread notifies its participants" do
    alice = user("Alice Smith")
    bob = user("Bob Jones")
    title = "Resolved #{System.unique_integer([:positive])}"
    page = a_page(alice, title)

    comment = comment!(page, block_id(page), "Please fix", bob)
    drain()
    _ = sent_emails(title)

    CMS.resolve_comment!(comment, actor: alice)
    drain()

    emails = sent_emails(title)

    assert Enum.any?(emails, &String.contains?(&1.subject, "Comment resolved"))
    assert address(bob) in recipients(emails)
  end

  test "an @name notifies that person, with the mention subject" do
    alice = user("Alice Smith")
    carol = user("Carol Danvers")
    title = "Mentioned #{System.unique_integer([:positive])}"
    page = a_page(alice, title)

    comment!(page, block_id(page), "#{handle(carol)} can you look at this?", alice)
    drain()

    emails = sent_emails(title)
    mention = Enum.find(emails, &String.contains?(&1.subject, "mentioned you"))

    assert mention, "expected a mention email"
    assert recipients([mention]) == [address(carol)]
    assert mention.html_body =~ "can you look at this?"
  end

  # Two emails for one comment is how people mute a feature.
  test "a mentioned participant gets the mention only, not both emails" do
    alice = user("Alice Smith")
    bob = user("Bob Jones")
    title = "Once #{System.unique_integer([:positive])}"
    page = a_page(alice, title)
    block = block_id(page)

    comment!(page, block, "First", bob)
    drain()
    _ = sent_emails(title)

    comment!(page, block, "#{handle(bob)} thoughts?", alice)
    drain()

    to_bob = Enum.filter(sent_emails(title), &(address(bob) in recipients([&1])))

    assert length(to_bob) == 1
    assert hd(to_bob).subject =~ "mentioned you"
  end

  test "a user who muted comment mail is skipped" do
    alice = user("Alice Smith")
    bob = user("Bob Jones", %{notify_on_comment: false})
    title = "Muted #{System.unique_integer([:positive])}"
    page = a_page(bob, title)

    comment!(page, block_id(page), "Hello", alice)
    drain()

    refute address(bob) in recipients(sent_emails(title))
  end

  # #1252 review: an editorial-intelligence automation reaction (#946) posts
  # comments built from record/duplicate titles, none of it sanitized against
  # accidentally containing an `@handle`-shaped substring. Nobody deliberately
  # typed such a body, so resolving mentions against it would let a document's
  # own title (possibly a draft's) decide who gets emailed an excerpt of it.
  test "an automation-authored comment never sends a mention email, even if its body contains a handle-shaped substring" do
    alice = user("Alice Smith")
    carol = user("Carol Danvers")
    title = "Automated #{System.unique_integer([:positive])}"
    page = a_page(alice, title)

    {:ok, _comment} =
      CMS.add_comment(
        %{
          content_type: "page",
          content_id: page.id,
          block_id: nil,
          body: "Looks like a duplicate of #{handle(carol)}'s other draft",
          created_by_rule_id: Ecto.UUID.generate()
        },
        actor: nil,
        authorize?: false
      )

    drain()

    emails = sent_emails(title)

    refute Enum.any?(emails, &String.contains?(&1.subject, "mentioned you"))
    refute address(carol) in recipients(emails)
    # The page's own author still hears about it normally (not as a mention) —
    # this only closes the accidental-mention side channel, not delivery.
    assert address(alice) in recipients(emails)
  end

  # The one token carrying free user input into an HTML email.
  test "a comment body cannot bring its own markup into the email" do
    alice = user("Alice Smith")
    bob = user("Bob Jones")
    title = "Escaped #{System.unique_integer([:positive])}"
    page = a_page(alice, title)

    comment!(page, block_id(page), "look <script>alert(1)</script> here", bob)
    drain()

    [email | _] = sent_emails(title)

    refute email.html_body =~ "<script>"
    assert email.html_body =~ "&lt;script&gt;"
  end
end
