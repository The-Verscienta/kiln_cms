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
    js = ["javascript", colon, "alert(1)"] |> Enum.join()

    page =
      CMS.create_page!(
        %{
          title: "URLs",
          slug: "urls-#{System.unique_integer([:positive])}",
          blocks: [
            %{type: :image, content: js, order: 0},
            %{type: :embed, content: js, order: 1}
          ]
        },
        actor: editor
      )

    # Unsafe *schemes* are stripped during the cast, so the url/content is blank.
    assert [%{type: :image, content: img}, %{type: :embed, content: emb}] = legacy_blocks(page)
    assert img in [nil, ""]
    assert emb in [nil, ""]
  end

  test "an embed URL from an unsupported host is kept, not blanked (#489)", %{editor: editor} do
    page =
      CMS.create_page!(
        %{
          title: "Embed",
          slug: "embed-#{System.unique_integer([:positive])}",
          blocks: [%{type: :embed, content: "https://example.com/a-thing", order: 0}]
        },
        actor: editor
      )

    # This used to be blanked: the save path ran `safe_embed_url/1`, which knows
    # two hosts and rewrites them, so every other URL an author pasted was
    # destroyed. Whether a URL may be *framed* is a render-time question — and
    # this one isn't framed, gets no card without resolved metadata, and renders
    # as an inert `<figure data-url>`. Blanking it lost the author's content to
    # buy nothing.
    assert [%{type: :embed, content: url}] = legacy_blocks(page)
    assert url == "https://example.com/a-thing"
  end

  test "a YouTube URL keeps its watch form rather than being rewritten (#489)", %{editor: editor} do
    page =
      CMS.create_page!(
        %{
          title: "YT",
          slug: "yt-#{System.unique_integer([:positive])}",
          blocks: [
            %{type: :embed, content: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", order: 0}
          ]
        },
        actor: editor
      )

    assert [%{type: :embed, content: url}] = legacy_blocks(page)
    assert url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    # …and still frames, because that decision moved to render time.
    assert KilnCMS.HTMLSanitizer.safe_embed_url(url) ==
             "https://www.youtube.com/embed/dQw4w9WgXcQ"
  end
end
