defmodule KilnCMS.Docs.TakeContentDownTest do
  @moduledoc """
  docs/take-content-down.md (#2475) quotes the sentences Kiln shows when it
  refuses a takedown, in italics, so a reader can match what is on their
  screen. Each one must be a msgid in `priv/gettext/default.pot`: a rewording
  in the code that the guide missed fails here instead of leaving the guide
  quoting a sentence nobody sees.

  The guide uses italics for nothing else, so every italic span is checked.
  """
  use ExUnit.Case, async: true

  @guide "docs/take-content-down.md"
  @pot "priv/gettext/default.pot"

  # A single-asterisk span on one line: `*text*`, not `**bold**`.
  @italic ~r/(?<!\*)\*(?!\*)([^*\n]+?)(?<!\*)\*(?!\*)/

  test "quotes refusal sentences" do
    assert length(quoted(File.read!(@guide))) >= 5
  end

  test "every sentence it quotes is a msgid in default.pot" do
    msgids = msgids()

    for sentence <- quoted(File.read!(@guide)) do
      assert MapSet.member?(msgids, sentence),
             "#{@guide} quotes #{inspect(sentence)}, which is not a msgid in #{@pot}"
    end
  end

  test "the check sees italics, and not bold" do
    assert quoted("**Unpublish** says *Only an admin.* and **Archive**") == ["Only an admin."]
  end

  defp quoted(markdown) do
    for [_span, sentence] <- Regex.scan(@italic, markdown), do: sentence
  end

  defp msgids do
    %Expo.Messages{messages: messages} = Expo.PO.parse_file!(@pot)

    for %Expo.Message.Singular{msgid: msgid} <- messages,
        into: MapSet.new(),
        do: IO.iodata_to_binary(msgid)
  end
end
