defmodule KilnCMS.CMS do
  @moduledoc """
  The CMS domain — core content modeling for KilnCMS.

  Holds the content-facing resources (`Page`, `Post`, `MediaItem`). Blocks are
  modeled as **embedded resources** stored as a JSON tree on each content
  resource (see decision D3 in the project plan), not as a separate table.
  """
  use Ash.Domain,
    extensions: [AshJsonApi.Domain, AshGraphql.Domain, AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource KilnCMS.CMS.Page
    resource KilnCMS.CMS.Page.Version
    resource KilnCMS.CMS.Post
    resource KilnCMS.CMS.Post.Version
    resource KilnCMS.CMS.MediaItem
  end
end
