defmodule KilnCMS.CMS.FormSpamSettingsTest do
  @moduledoc "Per-org disallowed-keyword list for the form spam scorer (#477)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "spam-settings-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp viewer do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "spam-settings-viewer-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  test "a site with no configured keywords has no row until saved" do
    admin = admin()
    assert CMS.list_form_spam_settings!(actor: admin) == []
  end

  test "save upserts the one-per-org row" do
    admin = admin()

    assert {:ok, first} = CMS.save_form_spam_settings(%{keywords: ["viagra"]}, actor: admin)
    assert first.keywords == ["viagra"]

    assert {:ok, updated} =
             CMS.save_form_spam_settings(%{keywords: ["viagra", "casino"]}, actor: admin)

    assert updated.id == first.id
    assert updated.keywords == ["viagra", "casino"]
    assert length(CMS.list_form_spam_settings!(actor: admin)) == 1
  end

  test "read and write are admin-only, unlike public settings resources" do
    admin = admin()
    viewer = viewer()
    CMS.save_form_spam_settings!(%{keywords: ["x"]}, actor: admin)

    # The read policy filters rather than rejecting the action outright, so a
    # viewer sees an empty list rather than an error — never the row itself.
    assert CMS.list_form_spam_settings!(actor: viewer) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.save_form_spam_settings(%{keywords: ["x"]}, actor: viewer)
  end
end
