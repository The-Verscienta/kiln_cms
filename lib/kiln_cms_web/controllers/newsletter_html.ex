defmodule KilnCMSWeb.NewsletterHTML do
  @moduledoc """
  Templates for the public newsletter pages (`KilnCMSWeb.NewsletterController`)
  that render in the site's own chrome: the double-opt-in confirmation (#1664)
  and every sign-up and unsubscribe message.
  """
  use KilnCMSWeb, :html

  embed_templates "newsletter_html/*"
end
