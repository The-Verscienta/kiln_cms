defmodule KilnCMS.CMS.SanitizeBlocksTest do
  @moduledoc "Block sanitization now happens inside the BlockUnion cast (Kiln v2)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  # Blocks are stored as the typed union; read back as legacy maps for assertions.
  defp legacy_blocks(record) do
    record.blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
  end

  setup do
    editor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "sanitize-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    %{editor: editor}
  end

  test "strips unsafe rich_text HTML on save", %{editor: editor} do
    page =
      CMS.create_page!(
        %{
          title: "Sanitize",
          slug: "sanitize-#{System.unique_integer([:positive])}",
          blocks: [
            %{
              type: :rich_text,
              content: "<p>OK</p><script>alert(1)</script>",
              order: 0
            }
          ]
        },
        actor: editor
      )

    assert [%{type: :rich_text, content: content}] = legacy_blocks(page)
    assert content =~ "OK"
    refute content =~ "script"
  end

  test "rejects unsafe image and embed URLs on save", %{editor: editor} do
    colon = <<58>>

    page =
      CMS.create_page!(
        %{
          title: "URLs",
          slug: "urls-#{System.unique_integer([:positive])}",
          blocks: [
            %{type: :image, content: ["javascript", colon, "alert(1)"] |> Enum.join(), order: 0},
            %{type: :embed, content: "https://evil.example/video", order: 1}
          ]
        },
        actor: editor
      )

    # Unsafe URLs are stripped during the cast, so the url/content is blank (nil).
    assert [%{type: :image, content: img}, %{type: :embed, content: emb}] = legacy_blocks(page)
    assert img in [nil, ""]
    assert emb in [nil, ""]
  end
end
