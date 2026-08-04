defmodule Kiln.Forms.SpamCheck.Checks.LinkDensity do
  @moduledoc """
  Flags a submission whose free-text fields carry an unusual number of links.
  A contact form asking "how did you hear about us?" might reasonably get
  one; comment-spam payloads carry several, because the link *is* the point.
  """
  use Kiln.Forms.SpamCheck

  alias Kiln.Forms.SpamCheck.Context

  @link_pattern ~r/\bhttps?:\/\/\S+|\bwww\.\S+/i
  @flag_at 3
  @weight 40

  @impl Kiln.Forms.SpamCheck
  def check(context) do
    count =
      context
      |> Context.text()
      |> then(&Regex.scan(@link_pattern, &1))
      |> length()

    if count >= @flag_at, do: flag(:too_many_links, @weight), else: :ok
  end
end
