defmodule KilnCMSWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use KilnCMSWeb, :html

  # Branded HTML error pages live in error_html/ (currently 404, rendered inside
  # Layouts.public with recovery links — #145). Statuses without a template fall
  # through to the plain-text status message below.
  embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
