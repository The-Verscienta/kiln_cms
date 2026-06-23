defmodule KilnCMS.CMS.Post do
  @moduledoc """
  A Post — blog/article content. Same embedded-block model, publishing workflow
  and relationships as `Page` (all from `KilnCMS.CMS.Content`), plus an
  `excerpt` for listings/feeds and a `:published` read for the blog index.
  """
  use KilnCMS.CMS.Content, type: :post, excerpt?: true, published?: true
end
