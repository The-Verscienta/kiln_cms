defmodule KilnCMS.CMS.ApprovalWorkflowTest do
  @moduledoc """
  Simple approval workflow: editors submit drafts for review; only admins publish
  or send content back to draft.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "wf-#{System.unique_integer([:positive])}"

  test "editors may submit drafts for review but not publish" do
    editor = user(:editor)
    admin = user(:admin)

    page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: editor)

    assert CMS.can_submit_page_for_review?(editor, page)
    refute CMS.can_publish_page?(editor, page)
    assert CMS.can_publish_page?(admin, page)

    in_review = CMS.submit_page_for_review!(page, %{}, actor: editor)
    assert in_review.state == :in_review
    refute CMS.can_publish_page?(editor, in_review)
    assert CMS.can_publish_page?(admin, in_review)
  end

  test "admin approves by publishing from in_review" do
    editor = user(:editor)
    admin = user(:admin)

    page = CMS.create_page!(%{title: "Ready", slug: slug()}, actor: editor)
    page = CMS.submit_page_for_review!(page, %{}, actor: editor)

    published = CMS.publish_page!(page, %{}, actor: admin)
    assert published.state == :published
    assert published.published_version_id
  end

  test "admin may return in_review content to draft; editors may not" do
    editor = user(:editor)
    admin = user(:admin)

    page = CMS.create_page!(%{title: "Needs work", slug: slug()}, actor: editor)
    page = CMS.submit_page_for_review!(page, %{}, actor: editor)

    refute CMS.can_return_page_to_draft?(editor, page)
    assert CMS.can_return_page_to_draft?(admin, page)

    draft = CMS.return_page_to_draft!(page, %{}, actor: admin)
    assert draft.state == :draft
  end

  test "editor publish attempts are rejected" do
    editor = user(:editor)
    page = CMS.create_page!(%{title: "Nope", slug: slug()}, actor: editor)

    assert {:error, %Ash.Error.Forbidden{}} = CMS.publish_page(page, %{}, actor: editor)
  end

  test "posts follow the same approval rules" do
    editor = user(:editor)
    admin = user(:admin)

    post = CMS.create_post!(%{title: "Post", slug: slug()}, actor: editor)
    refute CMS.can_publish_post?(editor, post)

    post = CMS.submit_post_for_review!(post, %{}, actor: editor)
    published = CMS.publish_post!(post, %{}, actor: admin)
    assert published.state == :published
  end

  # #879: each transition's UPDATE is now a compare-and-swap on the current
  # state, so a caller holding a stale struct can't clobber a row another writer
  # has already moved. The state machine only checks the in-memory struct, and
  # the UPDATE previously carried no state predicate — the repo's own "guards the
  # struct, not the row" hazard, widened by every headless request being a
  # separate get-then-update.
  test "a transition is a compare-and-swap and won't clobber a moved row (#879)" do
    admin = user(:admin)

    # A draft, captured as a now-stale in-memory struct.
    draft = CMS.create_post!(%{title: "CAS", slug: slug()}, actor: admin)

    # The row moves on underneath it: submitted for review, then published.
    in_review = CMS.submit_post_for_review!(draft, %{}, actor: admin)
    published = CMS.publish_post!(in_review, %{}, actor: admin)
    assert published.state == :published

    # Submitting the STALE :draft struct must NOT drag the published row back to
    # :in_review. Its in-memory state still satisfies the state machine's struct
    # check, but the CAS filter sees the row is no longer :draft, so the UPDATE
    # matches nothing and the write is refused rather than clobbering.
    assert {:error, _} = CMS.submit_post_for_review(draft, %{}, actor: admin)
    assert CMS.get_post!(published.id, actor: admin).state == :published
  end
end
