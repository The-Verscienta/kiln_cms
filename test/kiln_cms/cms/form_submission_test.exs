defmodule KilnCMS.CMS.FormSubmissionTest do
  @moduledoc """
  `FormSubmission` moderation (#477): the `:mark_spam`/`:mark_reviewed`
  actions, status filtering, and admin-only policies. The scoring pipeline
  itself is covered end-to-end in `KilnCMS.FormsTest`.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fs-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp viewer do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fs-viewer-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp form!(admin) do
    CMS.create_form!(%{name: "Contact", slug: "fs-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  defp submission!(form) do
    CMS.create_form_submission!(%{form_id: form.id, data: %{"message" => "hi"}},
      authorize?: false
    )
  end

  describe "mark_spam / mark_reviewed" do
    test "mark_spam flips a :new submission to :spam" do
      admin = admin()
      submission = submission!(form!(admin))
      assert submission.status == :new

      assert {:ok, marked} = CMS.mark_form_submission_spam(submission, %{}, actor: admin)
      assert marked.status == :spam
    end

    test "mark_reviewed corrects a false-positive :spam back to legitimate" do
      admin = admin()
      submission = submission!(form!(admin))
      {:ok, spam} = CMS.mark_form_submission_spam(submission, %{}, actor: admin)

      assert {:ok, reviewed} = CMS.mark_form_submission_reviewed(spam, %{}, actor: admin)
      assert reviewed.status == :reviewed
    end

    test "the original spam_score survives a manual status correction" do
      admin = admin()
      form = form!(admin)

      submission =
        CMS.create_form_submission!(
          %{form_id: form.id, data: %{"message" => "Buy http://a.co http://b.co http://c.co"}},
          authorize?: false
        )

      assert submission.spam_score > 0
      {:ok, reviewed} = CMS.mark_form_submission_reviewed(submission, %{}, actor: admin)
      assert reviewed.spam_score == submission.spam_score
    end
  end

  describe "status filtering" do
    test "recent_for_form filters by status when given, lists all when not" do
      admin = admin()
      form = form!(admin)
      new_one = submission!(form)
      {:ok, spam_one} = submission!(form) |> CMS.mark_form_submission_spam(%{}, actor: admin)

      all = CMS.recent_form_submissions!(form.id, actor: admin)
      assert length(all) == 2

      only_spam = CMS.recent_form_submissions!(form.id, %{status: :spam}, actor: admin)
      assert [%{id: id}] = only_spam
      assert id == spam_one.id

      only_new = CMS.recent_form_submissions!(form.id, %{status: :new}, actor: admin)
      assert [%{id: id}] = only_new
      assert id == new_one.id
    end
  end

  describe "policies" do
    test "admins may read, moderate and destroy; viewers may not" do
      admin = admin()
      viewer = viewer()
      submission = submission!(form!(admin))

      assert {:ok, _} = CMS.get_form_submission(submission.id, actor: admin)
      # A get_by read to a policy-denied actor comes back not-found rather
      # than forbidden — Ash filters the row out rather than revealing it
      # exists at all.
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.get_form_submission(submission.id, actor: viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.mark_form_submission_spam(submission, %{}, actor: viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_form_submission(submission, actor: viewer)
    end
  end

  describe "retention" do
    test "the prune trigger's window only ever matches :spam rows past the cutoff" do
      admin = admin()
      form = form!(admin)

      fresh_spam =
        submission!(form)
        |> CMS.mark_form_submission_spam!(%{}, actor: admin)

      stale_spam =
        submission!(form)
        |> CMS.mark_form_submission_spam!(%{}, actor: admin)
        |> Ash.Seed.update!(%{
          inserted_at:
            DateTime.add(
              DateTime.utc_now(),
              -(CMS.FormSubmission.spam_retention_days() + 1),
              :day
            )
        })

      stale_legit =
        submission!(form)
        |> Ash.Seed.update!(%{
          inserted_at:
            DateTime.add(
              DateTime.utc_now(),
              -(CMS.FormSubmission.spam_retention_days() + 1),
              :day
            )
        })

      due =
        CMS.FormSubmission
        |> Ash.Query.filter(
          status == :spam and
            inserted_at <= ago(^CMS.FormSubmission.spam_retention_days(), :day)
        )
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert stale_spam.id in due
      refute fresh_spam.id in due
      refute stale_legit.id in due
    end
  end
end
