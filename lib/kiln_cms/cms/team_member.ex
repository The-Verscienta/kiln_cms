defmodule KilnCMS.CMS.TeamMember do
  @moduledoc """
  A TeamMember — a KilnCMS content type. All of its behaviour (block editor,
  publishing workflow, version history, search, SEO, and the standard
  relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
  a TeamMember below.
  """
  use KilnCMS.CMS.Content, type: :team_member, excerpt?: true, published?: true
end
