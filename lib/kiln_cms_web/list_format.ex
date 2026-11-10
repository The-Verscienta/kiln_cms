defmodule KilnCMSWeb.ListFormat do
  @moduledoc """
  Joins a list of labels into a sentence fragment in the current locale:
  "A, B and C" in English, "A, B y C" in Spanish, "A, B et C" in French.

  The punctuation and the conjunction come from gettext, so each catalog
  decides how its own lists read (#2379). Two messages are enough for the
  locales Kiln ships: the separator between all but the last two items, and
  the pattern that joins the last two.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  @doc """
  Formats `items` as a list in the current gettext locale.

      iex> KilnCMSWeb.ListFormat.to_sentence(["Forms", "Webhooks", "Trash"])
      "Forms, Webhooks and Trash"
  """
  @spec to_sentence([String.t()]) :: String.t()
  def to_sentence([]), do: ""
  def to_sentence([only]), do: only

  def to_sentence(items) do
    {init, [last]} = Enum.split(items, -1)

    head =
      Enum.reduce(tl(init), hd(init), fn item, acc ->
        # The separator between list items before the last pair, as in "A, B and C".
        pgettext("list", "%{head}, %{item}", head: acc, item: item)
      end)

    # Joins the final item onto the rest of the list, as in "A, B and C".
    pgettext("list", "%{head} and %{last}", head: head, last: last)
  end
end
