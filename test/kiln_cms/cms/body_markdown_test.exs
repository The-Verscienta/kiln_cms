defmodule KilnCMS.CMS.BodyMarkdownTest do
  @moduledoc """
  `body_markdown` on the content write actions: the body as Markdown,
  converted by `KilnCMS.Markdown` into the typed blocks `block_tree` would
  carry — the argument JSON:API, GraphQL and the MCP tools all expose.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "body-md-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "body-md-#{System.unique_integer([:positive])}"

  defp types(record),
    do: Enum.map(record.blocks, &(&1.value.__struct__ |> Kiln.Block.Info.name() |> to_string()))

  test "create converts Markdown into typed blocks" do
    editor = user(:editor)

    page =
      CMS.create_page!(
        %{
          title: "Guide",
          slug: slug(),
          body_markdown: "Intro.\n\n![Map](https://img.example.com/m.png)\n\n- a\n- b"
        },
        actor: editor
      )

    assert types(page) == ["rich_text", "image", "rich_text"]
    [intro, _image, list] = page.blocks
    assert PortableText.to_plain_text(intro.value.body) == "Intro."
    assert Enum.map(list.value.body, & &1["listItem"]) == ["bullet", "bullet"]
  end

  test "update replaces the body; an update without it leaves the body alone" do
    editor = user(:editor)
    page = CMS.create_page!(%{title: "G", slug: slug(), body_markdown: "First."}, actor: editor)

    page = CMS.update_page!(page, %{body_markdown: "# Second"}, actor: editor)
    assert [%{value: %{body: [%{"style" => "h1"}]}}] = page.blocks

    page = CMS.update_page!(page, %{title: "Renamed"}, actor: editor)
    assert [%{value: %{body: [%{"style" => "h1"}]}}] = page.blocks
  end

  test "empty Markdown clears the body, like an empty block_tree" do
    editor = user(:editor)
    page = CMS.create_page!(%{title: "G", slug: slug(), body_markdown: "Some."}, actor: editor)

    assert CMS.update_page!(page, %{body_markdown: ""}, actor: editor).blocks == []
  end

  test "leading indentation survives — it is a code block, not whitespace to trim" do
    page =
      CMS.create_page!(%{title: "G", slug: slug(), body_markdown: "    mix test\n"},
        actor: user(:editor)
      )

    assert [%{value: %{body: [%{"style" => "code"} = code]}}] = page.blocks
    assert PortableText.to_plain_text([code]) == "mix test"
  end

  test "block_tree and body_markdown together are refused" do
    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.create_page(
               %{title: "G", slug: slug(), block_tree: [], body_markdown: "Hi"},
               actor: user(:editor)
             )

    assert Exception.message(error) =~ "send either block_tree or body_markdown, not both"
  end

  test "Markdown over the size limit is refused" do
    too_big = String.duplicate("a", KilnCMS.Markdown.max_bytes() + 1)

    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.create_page(%{title: "G", slug: slug(), body_markdown: too_big},
               actor: user(:editor)
             )

    assert Exception.message(error) =~ "is longer than"
  end

  # `body_markdown` rewrites `blocks` exactly as `block_tree` does, so it sits
  # behind the same grant — otherwise it is the way around it.
  test "body_markdown requires the blocks field grant" do
    post = CMS.create_post!(%{title: "Post", slug: slug()}, actor: user(:admin))
    title_only = user(:editor, %{field_grants: %{"post" => ["title"]}})

    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.update_post(post, %{body_markdown: "Hi"}, actor: title_only)

    assert Exception.message(error) =~ "field grant"

    blocks_granted = user(:editor, %{field_grants: %{"post" => ["title", "blocks"]}})
    assert {:ok, _} = CMS.update_post(post, %{body_markdown: "Hi"}, actor: blocks_granted)
  end
end
