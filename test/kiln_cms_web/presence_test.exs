defmodule KilnCMSWeb.PresenceTest do
  @moduledoc """
  `display_name/1` prefers the user's chosen name and never exposes the email
  local-part to other editors (#214).
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.Presence

  test "uses the user's display name when set" do
    assert Presence.display_name(%{name: "Jane Smith", email: "jane.smith@corp.com"}) ==
             "Jane Smith"
  end

  test "falls back to a neutral handle, never the email local-part" do
    assert Presence.display_name(%{name: nil, email: "jane.smith@corp.com"}) == "Someone"
    assert Presence.display_name(%{name: "", email: "jane.smith@corp.com"}) == "Someone"
  end

  test "handles users with no recognizable fields" do
    assert Presence.display_name(%{}) == "Someone"
  end
end
