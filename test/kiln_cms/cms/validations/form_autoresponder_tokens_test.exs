defmodule KilnCMS.CMS.Validations.FormAutoresponderTokensTest do
  @moduledoc """
  Config-time enforcement for `Form.autoresponder_subject`/`.autoresponder_body`
  (#468): must reference only tokens the form actually has, must be non-blank
  while the toggle is on, and must not re-validate against a stale field list
  when an unrelated tab (General, Fields) is what's actually being saved.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ar-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form_with_email_field!(actor) do
    form =
      CMS.create_form!(%{name: "Contact", slug: "ar-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, position: 0},
      actor: actor
    )

    form
  end

  test "accepts a template that only uses the form's own tokens" do
    actor = admin()
    form = form_with_email_field!(actor)

    assert {:ok, updated} =
             CMS.update_form(
               form,
               %{
                 autoresponder_enabled: true,
                 autoresponder_subject: "Thanks, [field:email]!",
                 autoresponder_body: "<p>From [form-name].</p>"
               },
               actor: actor
             )

    assert updated.autoresponder_enabled == true
  end

  test "rejects a token for a field the form doesn't have" do
    actor = admin()
    form = form_with_email_field!(actor)

    assert {:error, error} =
             CMS.update_form(
               form,
               %{
                 autoresponder_enabled: true,
                 autoresponder_subject: "Hi [field:phone]",
                 autoresponder_body: "body"
               },
               actor: actor
             )

    assert error_message(error) =~ "field:phone"
  end

  test "requires a non-blank subject and body while enabled" do
    actor = admin()
    form = form_with_email_field!(actor)

    assert {:error, error} =
             CMS.update_form(form, %{autoresponder_enabled: true}, actor: actor)

    message = error_message(error)
    assert message =~ "autoresponder_subject"
    assert message =~ "can't be blank"
  end

  test "a disabled autoresponder may stay blank or reference a token that no longer exists" do
    actor = admin()
    form = form_with_email_field!(actor)

    assert {:ok, _} =
             CMS.update_form(form, %{autoresponder_enabled: false}, actor: actor)

    assert {:ok, with_stale_token} =
             CMS.update_form(
               form,
               %{
                 autoresponder_enabled: false,
                 autoresponder_subject: "[field:vanished]",
                 autoresponder_body: "b"
               },
               actor: actor
             )

    assert with_stale_token.autoresponder_subject == "[field:vanished]"
  end

  test "saving an unrelated attribute does not re-validate the autoresponder templates" do
    actor = admin()
    form = form_with_email_field!(actor)

    {:ok, configured} =
      CMS.update_form(
        form,
        %{
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks, [field:email]!",
          autoresponder_body: "b"
        },
        actor: actor
      )

    # Deleting the field the template referenced would make the *current*
    # template invalid — but an unrelated General-tab save must not
    # re-run this validation against it.
    email_field = Enum.find(CMS.form_fields_for!(form.id, actor: actor), &(&1.name == "email"))
    CMS.destroy_form_field!(email_field, actor: actor)

    assert {:ok, renamed} =
             CMS.update_form(configured, %{name: "Contact Us"}, actor: actor)

    assert renamed.name == "Contact Us"
    assert renamed.autoresponder_subject == "Thanks, [field:email]!"
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end
end
