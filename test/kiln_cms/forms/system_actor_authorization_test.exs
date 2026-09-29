defmodule KilnCMS.Forms.SystemActorAuthorizationTest do
  @moduledoc """
  What the form pipeline is *authorized* to do, now that the submission write,
  the field reads, the two mail workers and the embed route's per-site default
  run as `Forms.system/0` instead of `authorize?: false` (#1659), and that the
  reads they decide on fail CLOSED when that grant is gone.

  Every grant has a refusal next to it: the system records a submission but
  cannot read, re-mark or delete one; it reads a form and its fields, active or
  not, but cannot edit either; it reads the site's embed default but cannot
  save it.

  Reads assert on the ROW, never on `{:ok, _}`: a refused read under a filter
  policy comes back empty (or `NotFound`), so a shape-only assertion would pass
  with the grant removed. The fail-closed tests assert on what a filtered read
  could NOT produce — a raise, a `Forbidden`, or the closed answer and the log
  line the error path writes.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures
  import Swoosh.TestAssertions

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormSubmission
  alias KilnCMS.Forms
  alias KilnCMS.Forms.{Autoresponder, AutoresponderWorker, EmbedPolicy, NotificationWorker}
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Forms.system()
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp form!(attrs \\ %{}) do
    admin = user(:admin)

    form =
      CMS.create_form!(Map.merge(%{name: "Contact", slug: "fsa-#{uniq()}"}, attrs), actor: admin)

    CMS.create_form_field!(
      %{form_id: form.id, position: 0, name: "email", label: "Email", field_type: :email},
      actor: admin
    )

    form
  end

  defp inactive_form!(attrs \\ %{}), do: form!(Map.put(attrs, :active, false))

  defp stored_submissions(form) do
    FormSubmission
    |> Ash.read!(authorize?: false, tenant: org_id())
    |> Enum.filter(&(&1.form_id == form.id))
  end

  defp submission!(form) do
    CMS.create_form_submission!(%{form_id: form.id, data: %{"email" => "a@example.com"}},
      authorize?: false,
      tenant: org_id()
    )
  end

  test "Forms.system/0 is a system actor labelled :forms" do
    assert %SystemActor{subsystem: :forms} = Forms.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Forms.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :forms} = Forms.system()
    assert Forms.with_actor(nil, &Forms.system/0) == nil
  end

  describe "Form and FormField — definitions" do
    test "the system reads an inactive form and its fields; no actor reads neither" do
      form = inactive_form!()

      assert {:ok, %{id: id}} = CMS.get_form(form.id, actor: system(), tenant: org_id())
      assert id == form.id
      assert [%{name: "email"}] = CMS.form_fields_for!(form.id, actor: system(), tenant: org_id())

      assert {:error, _not_found} = CMS.get_form(form.id, tenant: org_id())
      assert [] == CMS.form_fields_for!(form.id, tenant: org_id())
    end

    test "the system edits and deletes no form and no field" do
      form = form!()
      [field] = CMS.form_fields_for!(form.id, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_form(form, %{name: "Hijacked"}, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_form(form, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_form(%{name: "New", slug: "fsa-new-#{uniq()}"},
                 actor: system(),
                 tenant: org_id()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_form_field(field, %{label: "x"}, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_form_field(field, actor: system(), tenant: org_id())
    end
  end

  describe "FormSubmission — visitor data" do
    test "the system records a submission; no actor and an editor cannot" do
      form = form!()

      assert {:ok, submission} =
               CMS.create_form_submission(%{form_id: form.id, data: %{"email" => "a@b.test"}},
                 actor: system(),
                 tenant: org_id()
               )

      assert submission.id in Enum.map(stored_submissions(form), & &1.id)

      for actor <- [nil, user(:editor)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.create_form_submission(%{form_id: form.id, data: %{}},
                   actor: actor,
                   tenant: org_id()
                 )
      end
    end

    test "the system reads, re-marks and deletes no submission" do
      form = form!()
      submission = submission!(form)

      assert {:error, _} =
               CMS.get_form_submission(submission.id, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.mark_form_submission_spam(submission, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(submission, actor: system(), tenant: org_id())

      assert [%{status: status}] = stored_submissions(form)
      refute status == :spam
    end
  end

  describe "SiteEmbedSettings — the embed route's default" do
    test "the system reads the row but cannot save it; no actor reads nothing" do
      org = org("fsa-embed-#{uniq()}").id

      CMS.save_site_embed_settings!(%{embed_origins: ["https://partner.test"]},
        authorize?: false,
        tenant: org
      )

      assert EmbedPolicy.org_default(org) == ["https://partner.test"]
      assert [] == CMS.list_site_embed_settings!(tenant: org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_embed_settings(%{embed_origins: ["https://evil.test"]},
                 actor: system(),
                 tenant: org
               )

      assert EmbedPolicy.org_default(org) == ["https://partner.test"]
    end
  end

  describe "fail closed: a lost grant never reads as \"nothing\"" do
    test "a submission to a form deactivated since it was loaded raises and stores nothing" do
      form = form!()
      stale = CMS.get_form!(form.id, actor: system(), tenant: org_id())
      CMS.update_form!(form, %{active: false}, authorize?: false, tenant: org_id())

      assert_raise Ash.Error.Forbidden, fn ->
        Forms.with_actor(nil, fn -> Forms.submit(stale, %{"email" => "a@b.test"}) end)
      end

      assert stored_submissions(form) == []
    end

    test "the notification worker fails the job instead of dropping the mail" do
      form = inactive_form!(%{notify_email: "team@example.com"})
      args = %{"form_id" => form.id, "org_id" => org_id(), "data" => %{"m" => "hi"}}

      assert {:error, %Ash.Error.Forbidden{}} =
               Forms.with_actor(nil, fn -> perform_job(NotificationWorker, args) end)

      assert_no_email_sent()

      assert :ok = perform_job(NotificationWorker, args)
      assert_email_sent(fn email -> assert email.to == [{"", "team@example.com"}] end)
    end

    test "the autoresponder worker fails the job instead of dropping the confirmation" do
      form = inactive_form!()

      form =
        CMS.update_form!(
          form,
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Thanks",
            autoresponder_body: "We got [field:email]"
          },
          authorize?: false,
          tenant: org_id()
        )

      args = %{
        "form_id" => form.id,
        "org_id" => org_id(),
        "to" => "v@x.test",
        "data" => %{"email" => "v@x.test"}
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               Forms.with_actor(nil, fn -> perform_job(AutoresponderWorker, args) end)

      assert_no_email_sent()

      assert :ok = perform_job(AutoresponderWorker, args)
      assert_email_sent(fn email -> assert email.html_body =~ "v@x.test" end)
    end

    test "the template's field lookup raises rather than call every token unknown" do
      form = inactive_form!()

      assert_raise Ash.Error.Forbidden, fn ->
        Forms.with_actor(nil, fn ->
          Autoresponder.definitions_for_form(form.id, "Contact", false, org_id())
        end)
      end

      names =
        form.id
        |> Autoresponder.definitions_for_form("Contact", false, org_id())
        |> Kiln.Tokens.names()

      assert "field:email" in names
    end

    test "an unreadable embed default closes framing, never inherits the deployment's" do
      org = org("fsa-embed-closed-#{uniq()}").id

      CMS.save_site_embed_settings!(%{embed_origins: ["https://partner.test"]},
        authorize?: false,
        tenant: org
      )

      log =
        capture_log(fn ->
          assert Forms.with_actor(nil, fn -> EmbedPolicy.org_default(org) end) == []
        end)

      assert log =~ "could not read #{org}'s embed default"

      form = %{embed_origins: nil, org_id: org}

      capture_log(fn ->
        assert %{embed_origins: []} = Forms.with_actor(nil, fn -> EmbedPolicy.effective(form) end)
      end)
    end
  end
end
