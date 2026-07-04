defmodule ShowcaseWeb.ErrorHTML do
  @moduledoc false
  use ShowcaseWeb, :html

  # Render "404.html", "500.html", etc. as their plain status message.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
