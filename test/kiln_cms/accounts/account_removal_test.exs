defmodule KilnCMS.Accounts.AccountRemovalTest do
  @moduledoc """
  Removing an account and deciding what happens to what it wrote: the three
  dispositions, and the ordering that makes a partial run recoverable.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountRemoval
  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "removal-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org_id, do: Accounts.default_org_id()

  # Created as `author` (so the byline is theirs) and published as `admin`, since
  # an editor can't publish their own work unless the site says so.
  defp post_by(author, opts \\ []) do
    post =
      CMS.create_post!(
        %{
          title: "Piece #{System.unique_integer([:positive])}",
          slug: "removal-#{System.unique_integer([:positive])}"
        },
        actor: author,
        tenant: org_id()
      )

    case Keyword.get(opts, :publisher) do
      nil -> post
      admin -> CMS.publish_post!(post, %{}, actor: admin, tenant: org_id())
    end
  end

  defp reread(post), do: CMS.get_post(post.id, authorize?: false, tenant: org_id())

  # One admin, deliberately: the departing accounts below are editors, so the
  # last-admin guard never fires for them — and the ordering test at the bottom
  # needs an erasure that IS refused, which this admin being the only one gives it.
  setup do
    %{admin: user(:admin), author: user(:editor)}
  end

  describe ":keep" do
    test "erases the account and leaves the content in place", %{admin: admin, author: author} do
      post = post_by(author, publisher: admin)

      assert {:ok, %{disposition: :keep, affected: 0, failed: 0}} =
               AccountRemoval.remove(author, :keep, actor: admin)

      assert {:ok, kept} = reread(post)
      assert kept.state == :published
      # The byline still points at the row — which no longer names a person.
      assert kept.author_id == author.id
      erased = Accounts.get_user!(author.id, authorize?: false)
      assert erased.anonymized_at
      assert is_nil(erased.name)
    end
  end

  describe ":archive" do
    test "archives every document the account authored", %{admin: admin, author: author} do
      published = post_by(author, publisher: admin)
      draft = post_by(author)

      assert {:ok, %{affected: 2, failed: 0}} =
               AccountRemoval.remove(author, :archive, actor: admin)

      assert {:ok, %{state: :archived}} = reread(published)
      assert {:ok, %{state: :archived}} = reread(draft)
      # Archiving is reversible, which is the point of offering it over a delete.
      assert {:ok, back} =
               CMS.unarchive_post(elem(reread(draft), 1), %{}, actor: admin, tenant: org_id())

      assert back.state == :draft
    end

    test "leaves other authors' content alone", %{admin: admin, author: author} do
      mine = post_by(author)
      theirs = post_by(user(:editor))

      assert {:ok, _} = AccountRemoval.remove(author, :archive, actor: admin)

      assert {:ok, %{state: :archived}} = reread(mine)
      assert {:ok, %{state: :draft}} = reread(theirs)
    end

    # `:archive`'s compare-and-swap refuses an already-archived record, which is
    # not a failure to report — it is already where the admin asked for it.
    test "an already-archived document is not counted as a failure", %{
      admin: admin,
      author: author
    } do
      post = post_by(author)
      CMS.archive_post!(post, %{}, actor: admin, tenant: org_id())

      assert {:ok, %{failed: 0}} = AccountRemoval.remove(author, :archive, actor: admin)
    end
  end

  describe ":trash" do
    test "soft-deletes the content, restorable from the trash", %{admin: admin, author: author} do
      post = post_by(author, publisher: admin)

      assert {:ok, %{affected: 1, failed: 0}} =
               AccountRemoval.remove(author, :trash, actor: admin)

      # Gone from ordinary reads (AshArchival's filter) but not from the trash.
      assert {:error, _} = reread(post)

      trashed = CMS.list_trashed_posts!(actor: admin, tenant: org_id())
      assert post.id in Enum.map(trashed, & &1.id)

      assert {:ok, restored} =
               CMS.restore_post(hd(trashed), %{}, actor: admin, tenant: org_id())

      assert restored.id == post.id
    end
  end

  describe "authored_counts/1" do
    test "counts per type and skips empty ones", %{author: author} do
      for _ <- 1..3, do: post_by(author)

      %{counts: counts, unreadable: []} = AccountRemoval.authored_counts(author)

      assert {"Post", 3} in counts
      refute Enum.any?(counts, fn {label, _} -> label == "Page" end)
    end

    test "is empty for an account that wrote nothing", %{author: author} do
      assert AccountRemoval.authored_counts(author) == %{counts: [], unreadable: []}
    end
  end

  describe "preflight" do
    # A refusal that is knowable before any write must be reported before any
    # write. The previous order trashed every document and THEN reported only the
    # refusal, as if nothing had happened.
    test "an erasure the last-admin guard refuses touches no content", %{admin: admin} do
      post = post_by(admin, publisher: admin)

      assert {:error, error} = AccountRemoval.remove(admin, :trash, actor: admin)
      assert Exception.message(error) =~ "no admin"

      # Still published, not in the trash.
      assert {:ok, %{state: :published}} = reread(post)
      still_there = Accounts.get_user!(admin.id, authorize?: false)
      assert is_nil(still_there.anonymized_at)
    end

    test "an actor the erasure policy refuses touches no content", %{author: author} do
      editor = user(:editor)
      post = post_by(author)

      assert {:error, %Ash.Error.Forbidden{}} =
               AccountRemoval.remove(author, :archive, actor: editor)

      assert {:ok, %{state: :draft}} = reread(post)
    end
  end

  describe "the result" do
    test "reports which types could not be read, and none on a clean run", %{
      admin: admin,
      author: author
    } do
      post_by(author)

      assert {:ok, %{affected: 1, failed: 0, unreadable: []}} =
               AccountRemoval.remove(author, :archive, actor: admin)
    end
  end
end
