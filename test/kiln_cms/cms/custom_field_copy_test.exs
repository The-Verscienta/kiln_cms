defmodule KilnCMS.CMS.CustomFieldCopyTest do
  @moduledoc """
  Copy and import paths under per-custom-field grants (#2281): `Duplication`,
  `Translations` and `Portability.Import` carry only the custom-field keys the
  acting editor could write by hand (granted, and not hidden by a read
  restriction), and report what they left out like any other withheld
  attribute. An admin's copy is whole.
  """
  # async: false — the private-field name cache is global per org.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Duplication
  alias KilnCMS.CMS.Translations
  alias KilnCMS.Portability.Import

  @canary "CANARY-7f3a"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "copy-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "copy-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "Field", field_type: :string}, attrs),
      actor: admin
    )
  end

  setup do
    admin = user(:admin)

    field!(admin, %{name: "notes"})
    field!(admin, %{name: "summary"})
    field!(admin, %{name: "secret", private: true})

    source =
      CMS.create_post!(
        %{
          title: "Source",
          slug: slug(),
          custom_fields: %{"notes" => "N", "summary" => "S", "secret" => @canary}
        },
        actor: admin
      )

    %{
      admin: admin,
      source: source,
      org: source.org_id,
      hidden: user(:editor, %{field_read_grants: %{"post" => []}}),
      per_key: user(:editor, %{field_grants: %{"post" => ["title", "custom_fields.notes"]}}),
      open: user(:editor)
    }
  end

  defp stored(copy, admin), do: CMS.get_post!(copy.id, actor: admin).custom_fields

  describe "Duplication" do
    test "an editor who cannot read a private field copies without it, and is told", ctx do
      {copy, withheld} =
        Duplication.duplicate_with_notes!(:post, ctx.source, actor: ctx.hidden, tenant: ctx.org)

      assert stored(copy, ctx.admin) == %{"notes" => "N", "summary" => "S"}
      assert "custom_fields.secret" in withheld
    end

    test "an editor with a per-key grant copies only the keys it names", ctx do
      {copy, withheld} =
        Duplication.duplicate_with_notes!(:post, ctx.source, actor: ctx.per_key, tenant: ctx.org)

      fields = stored(copy, ctx.admin)
      assert fields["notes"] == "N"
      refute Map.has_key?(fields, "summary")
      refute Map.has_key?(fields, "secret")
      assert "custom_fields.summary" in withheld
      assert "custom_fields.secret" in withheld
    end

    test "an unrestricted editor's and an admin's copies are whole", ctx do
      for actor <- [ctx.open, ctx.admin] do
        {copy, withheld} =
          Duplication.duplicate_with_notes!(:post, ctx.source, actor: actor, tenant: ctx.org)

        assert stored(copy, ctx.admin) == ctx.source.custom_fields
        refute Enum.any?(withheld, &String.starts_with?(&1, "custom_fields"))
      end
    end
  end

  describe "Translations" do
    test "a translation drops what the editor cannot read or write", ctx do
      {hidden_copy, hidden_notes} =
        Translations.create_translation_with_notes!(:post, ctx.source, "fr",
          actor: ctx.hidden,
          tenant: ctx.org
        )

      assert stored(hidden_copy, ctx.admin) == %{"notes" => "N", "summary" => "S"}
      assert "custom_fields.secret" in hidden_notes

      {granted_copy, granted_notes} =
        Translations.create_translation_with_notes!(:post, ctx.source, "de",
          actor: ctx.per_key,
          tenant: ctx.org
        )

      assert %{"notes" => "N"} = stored(granted_copy, ctx.admin)
      refute Map.has_key?(stored(granted_copy, ctx.admin), "summary")
      assert "custom_fields.summary" in granted_notes
    end

    test "an admin's translation carries every key", ctx do
      {copy, _notes} =
        Translations.create_translation_with_notes!(:post, ctx.source, "es",
          actor: ctx.admin,
          tenant: ctx.org
        )

      assert stored(copy, ctx.admin) == ctx.source.custom_fields
    end
  end

  describe "Import" do
    defp envelope(fields) do
      %{
        "records" => [
          %{"type" => "post", "title" => "Imported", "slug" => slug(), "custom_fields" => fields}
        ]
      }
    end

    test "an editor imports only the keys it may write, and the report says so", ctx do
      fields = %{"notes" => "N", "summary" => "S", "secret" => @canary}

      {:ok, report} =
        Import.run_envelope(envelope(fields),
          actor: ctx.per_key,
          tenant: ctx.org,
          skip_media: true
        )

      assert report.failed == []
      [created] = report.created
      assert Enum.any?(created.issues, &(&1 =~ "custom_fields.summary"))
      assert stored(%{id: created.id}, ctx.admin) == %{"notes" => "N"}

      {:ok, report} =
        Import.run_envelope(envelope(fields),
          actor: ctx.hidden,
          tenant: ctx.org,
          skip_media: true
        )

      assert report.failed == []
      [created] = report.created
      assert Enum.any?(created.issues, &(&1 =~ "custom_fields.secret"))
      assert stored(%{id: created.id}, ctx.admin) == %{"notes" => "N", "summary" => "S"}
    end

    test "an admin imports every key", ctx do
      fields = %{"notes" => "N", "secret" => @canary}

      {:ok, report} =
        Import.run_envelope(envelope(fields), actor: ctx.admin, tenant: ctx.org, skip_media: true)

      [created] = report.created
      assert created.issues == []
      assert stored(%{id: created.id}, ctx.admin) == fields
    end
  end
end
