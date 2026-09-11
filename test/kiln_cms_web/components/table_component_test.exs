defmodule KilnCMSWeb.TableComponentTest do
  @moduledoc """
  `<.table row_click>` puts the click handler on every cell, which is
  mouse-only: nothing in the row can take focus. The first cell must also be
  focusable and fire the same handler on Enter, or a keyboard user can't open
  a row at all.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import KilnCMSWeb.CoreComponents

  @wiring ~w(phx-click phx-keydown phx-key tabindex)

  defp cell_wiring(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("tbody td")
    |> Enum.map(fn {"td", attrs, _children} -> attrs |> Map.new() |> Map.take(@wiring) end)
  end

  test "with row_click, the first cell is focusable and opens the row on Enter" do
    assigns = %{rows: [%{id: 7, name: "Home"}]}

    html =
      rendered_to_string(~H"""
      <.table id="pages" rows={@rows} row_click={fn row -> "open-#{row.id}" end}>
        <:col :let={row} label="Name">{row.name}</:col>
        <:col :let={row} label="Id">{row.id}</:col>
      </.table>
      """)

    assert cell_wiring(html) == [
             %{
               "phx-click" => "open-7",
               "phx-keydown" => "open-7",
               "phx-key" => "Enter",
               "tabindex" => "0"
             },
             %{"phx-click" => "open-7"}
           ]
  end

  test "without row_click, no cell is focusable or wired" do
    assigns = %{rows: [%{id: 7, name: "Home"}]}

    html =
      rendered_to_string(~H"""
      <.table id="pages" rows={@rows}>
        <:col :let={row} label="Name">{row.name}</:col>
        <:col :let={row} label="Id">{row.id}</:col>
      </.table>
      """)

    assert cell_wiring(html) == [%{}, %{}]
  end
end
