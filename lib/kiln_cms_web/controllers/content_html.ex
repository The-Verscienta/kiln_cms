defmodule KilnCMSWeb.ContentHTML do
  @moduledoc """
  Templates for the public content delivery frontend (`ContentController`).
  """
  use KilnCMSWeb, :html

  alias KilnCMSWeb.BlockComponents

  embed_templates "content_html/*"
end
