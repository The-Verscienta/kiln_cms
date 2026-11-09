defmodule KilnCMS.Forms.ChallengeTest do
  @moduledoc """
  Human verification inside the public-form pipeline (#2249): when
  `KilnCMS.Forms.submit/3` asks the provider, and what each answer does to the
  submission — stored, held as spam, or refused.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures

  alias Kiln.Forms.SpamCheck
  alias KilnCMS.CMS
  alias KilnCMS.Forms

  setup do
    enable!()
    admin = KilnCMS.FormFixtures.admin()

    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["form.submitted"]},
      actor: admin
    )

    form =
      KilnCMS.FormFixtures.form!(
        %{notify_email: "team@example.com", challenge: :always},
        actor: admin
      )

    CMS.update_form!(
      CMS.get_form!(form.id, authorize?: false),
      %{
        autoresponder_enabled: true,
        autoresponder_subject: "Thanks",
        autoresponder_body: "We got it."
      },
      actor: admin
    )

    %{form: Forms.get_active(form.slug), admin: admin}
  end

  defp params(extra), do: Map.merge(%{"email" => "visitor@example.com"}, extra)

  defp refute_side_effects do
    refute_enqueued(worker: KilnCMS.Forms.NotificationWorker)
    refute_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)
    assert CMS.recent_webhook_deliveries!(authorize?: false) == []
  end

  test "a passing token stores the submission as :passed, and everything runs", %{form: form} do
    assert {:ok, submission} = Forms.submit(form, params(%{"_kiln_challenge" => "pass"}))

    assert submission.challenge == :passed
    assert submission.status == :new
    assert_enqueued(worker: KilnCMS.Forms.NotificationWorker)
    assert_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)
    assert [_delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
  end

  test "the provider's own field name is accepted when ours is absent", %{form: form} do
    assert {:ok, submission} = Forms.submit(form, params(%{"cf-turnstile-response" => "pass"}))
    assert submission.challenge == :passed
    assert_received {:challenge_verify, "pass", _opts}
  end

  test "ours wins when both are sent", %{form: form} do
    assert {:error, _} =
             Forms.submit(
               form,
               params(%{"_kiln_challenge" => "fail", "cf-turnstile-response" => "pass"})
             )
  end

  for {name, token, outcome} <- [
        {"no token", nil, :missing},
        {"a token the provider could not check", "down", :unavailable},
        {"a token solved on another host", "wrong-host", :wrong_host}
      ] do
    test "#{name} is held: stored as spam, nobody mailed, no webhook", %{form: form} do
      extra = if unquote(token), do: %{"_kiln_challenge" => unquote(token)}, else: %{}

      assert {:ok, submission} = Forms.submit(form, params(extra))

      assert submission.challenge == unquote(outcome)
      assert submission.status == :spam
      assert submission.spam_score >= SpamCheck.threshold()
      assert submission.data == %{"email" => "visitor@example.com"}
      refute_side_effects()
    end
  end

  test "a refused token returns the form with an error, and stores nothing", %{form: form} do
    assert {:error, errors} = Forms.submit(form, params(%{"_kiln_challenge" => "fail"}))

    assert errors == %{"_kiln_challenge" => Forms.challenge_refused_message()}
    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
    refute_side_effects()
  end

  test "a tripped honeypot is discarded before the provider is asked", %{form: form} do
    assert {:ok, :discarded} =
             Forms.submit(
               form,
               params(%{"_kiln_challenge" => "pass", Forms.honeypot_field() => "bot"})
             )

    refute_received {:challenge_verify, _, _}
  end

  test "a field error is reported without spending the token", %{form: form} do
    assert {:error, %{"email" => _}} =
             Forms.submit(form, %{"email" => "nope", "_kiln_challenge" => "pass"})

    refute_received {:challenge_verify, _, _}
  end

  test "the client address reaches the provider only when the operator sends it", %{form: form} do
    Forms.submit(form, params(%{"_kiln_challenge" => "pass"}), remote_ip: "203.0.113.7")
    assert_received {:challenge_verify, "pass", opts}
    assert opts[:remote_ip] == nil

    enable!(send_remote_ip: true)
    Forms.submit(form, params(%{"_kiln_challenge" => "pass"}), remote_ip: "203.0.113.7")
    assert_received {:challenge_verify, "pass", opts}
    assert opts[:remote_ip] == "203.0.113.7"
  end

  test "a form left :off stores no outcome and never asks the provider", %{admin: admin} do
    form = Forms.get_active(KilnCMS.FormFixtures.form!(%{}, actor: admin).slug)

    assert {:ok, submission} = Forms.submit(form, params(%{"_kiln_challenge" => "fail"}))
    assert submission.challenge == nil
    assert submission.status == :new
    refute_received {:challenge_verify, _, _}
  end

  test "with forms turned off by the operator, an :always form submits as before", %{form: form} do
    enable!(forms: false)

    assert {:ok, submission} = Forms.submit(form, params(%{}))
    assert submission.challenge == nil
    assert submission.status == :new
  end

  test "the create refuses an outcome outside the known set" do
    form = Forms.get_active(KilnCMS.FormFixtures.form!().slug)

    assert_raise Ash.Error.Invalid, fn ->
      CMS.create_form_submission!(
        %{form_id: form.id, data: %{}, challenge: :bogus},
        actor: Forms.system(),
        tenant: form.org_id
      )
    end
  end
end
