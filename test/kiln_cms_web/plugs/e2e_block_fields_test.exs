defmodule KilnCMSWeb.Plugs.E2EBlockFieldsTest do
  @moduledoc false
  # Rewrites the VM-global `:i18n` config, which every request reads — so not
  # async (see `KilnCMS.I18n.FieldLocalization.block_fields/1`).
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMSWeb.Plugs.E2EBlockFields

  @image %{"image" => %{"shared" => ["url", "media_id"], "fallback" => ["alt", "caption"]}}

  setup do
    previous = Application.get_env(:kiln_cms, :i18n)
    Application.put_env(:kiln_cms, :i18n, Keyword.delete(previous, :block_fields))
    on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)
  end

  defp call(method, params) do
    conn(method, "/", params) |> E2EBlockFields.call(E2EBlockFields.init([]))
  end

  test "POST sets the block fields and answers with what it had" do
    conn = call(:post, %{"block_fields" => @image})
    assert conn.status == 200
    assert conn.halted
    assert Jason.decode!(conn.resp_body) == %{"block_fields" => @image, "was" => %{}}

    assert Application.get_env(:kiln_cms, :i18n)[:block_fields] ==
             %{"image" => [shared: [:url, :media_id], fallback: [:alt, :caption]]}

    assert FieldLocalization.block_fields(KilnCMS.Blocks.Image) ==
             %{url: :shared, media_id: :shared, alt: :fallback, caption: :fallback}

    conn = call(:post, %{"block_fields" => %{}})
    assert Jason.decode!(conn.resp_body) == %{"block_fields" => %{}, "was" => @image}
    refute Keyword.has_key?(Application.get_env(:kiln_cms, :i18n), :block_fields)
    assert FieldLocalization.block_fields(KilnCMS.Blocks.Image) == %{}
  end

  test "an unknown block type or field is refused and changes nothing" do
    for bad <- [
          %{"nope" => %{"shared" => ["url"]}},
          %{"image" => %{"shared" => ["not_a_field"]}},
          %{"image" => %{"other" => ["url"]}},
          %{"image" => %{"shared" => "url"}},
          %{"image" => %{"shared" => [1]}},
          %{"image" => ["url"]}
        ] do
      assert call(:post, %{"block_fields" => bad}).status == 400
    end

    assert call(:post, %{}).status == 400
    assert call(:post, %{"block_fields" => "image"}).status == 400
    refute Keyword.has_key?(Application.get_env(:kiln_cms, :i18n), :block_fields)
  end

  test "a GET changes nothing" do
    conn = call(:get, %{"block_fields" => @image})
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]
    refute Keyword.has_key?(Application.get_env(:kiln_cms, :i18n), :block_fields)
  end
end
