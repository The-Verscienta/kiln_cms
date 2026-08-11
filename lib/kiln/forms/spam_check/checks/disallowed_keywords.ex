defmodule Kiln.Forms.SpamCheck.Checks.DisallowedKeywords do
  @moduledoc """
  Flags a submission whose free-text fields contain any of the org's own
  disallowed-keyword list (`KilnCMS.CMS.FormSpamSettings`). Case-insensitive
  substring match — deliberately simple, and deliberately not shipped with a
  default list: what counts as spam vocabulary is domain-specific, and a
  built-in list would either be useless (too narrow) or a false-positive
  generator (too broad) for most deployments.
  """
  use Kiln.Forms.SpamCheck

  alias Kiln.Forms.SpamCheck.Context

  @weight 50

  @impl Kiln.Forms.SpamCheck
  def check(%Context{keywords: []}), do: :ok

  def check(context) do
    text = context |> Context.text() |> String.downcase()

    if Enum.any?(context.keywords, &String.contains?(text, String.downcase(&1))) do
      flag(:disallowed_keyword, @weight)
    else
      :ok
    end
  end
end
