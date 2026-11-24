defmodule KilnCMS.CMS.KeysetCursorSigningTest do
  @moduledoc """
  Keyset cursors are signed (#3272, EEF-CVE-2026-124283): Ash decodes only a
  cursor this deployment issued. A cursor built by hand, or one with a byte
  changed, is refused before its contents are decoded, so a struct smuggled
  into one never reaches the data layer.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  setup do
    title = "kcs #{System.unique_integer([:positive])}"

    for _ <- 1..3 do
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: title,
        slug: "kcs-#{System.unique_integer([:positive])}",
        locale: "en",
        state: :published,
        custom_fields: %{}
      })
    end

    %{title: title}
  end

  defp page(title, page_opts),
    do: CMS.list_pages(%{}, page: page_opts, query: [filter: [title: title]])

  test "a signing secret is configured" do
    assert is_binary(Application.get_env(:ash, :keyset_signing_secret))
  end

  test "the cursor a page hands out reads the next page", %{title: title} do
    {:ok, first} = page(title, limit: 1)
    cursor = hd(first.results).__metadata__.keyset

    assert {:ok, %{results: [_]}} = page(title, limit: 1, after: cursor)
  end

  test "a cursor with one byte changed is refused", %{title: title} do
    {:ok, first} = page(title, limit: 1)

    <<head::binary-size(40), byte, rest::binary>> =
      Base.decode64!(hd(first.results).__metadata__.keyset)

    tampered = Base.encode64(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)

    assert {:error, error} = page(title, limit: 1, after: tampered)
    assert Exception.message(error) =~ "Invalid value provided as a keyset"
  end

  test "an unsigned cursor carrying a struct is refused", %{title: title} do
    forged =
      [%Ash.CiString{string: "x", casted?: true}, Ecto.UUID.generate()]
      |> :erlang.term_to_binary()
      |> Base.encode64()

    assert {:error, error} = page(title, limit: 1, after: forged)
    assert Exception.message(error) =~ "Invalid value provided as a keyset"
  end

  test "an unsigned JSON cursor is refused", %{title: title} do
    forged = Base.encode64(Jason.encode!(["x", Ecto.UUID.generate()]))

    assert {:error, error} = page(title, limit: 1, after: forged)
    assert Exception.message(error) =~ "Invalid value provided as a keyset"
  end
end
