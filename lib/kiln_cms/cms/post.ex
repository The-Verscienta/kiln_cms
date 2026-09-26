defmodule KilnCMS.CMS.Post do
  @moduledoc """
  A Post — blog/article content. Same embedded-block model, publishing workflow
  and relationships as `Page` (all from `KilnCMS.CMS.Content`), plus an
  `excerpt` for listings/feeds.
  """
  # Posts fire their :json_ld main node as a BlogPosting — the accurate
  # Article subtype for blog content (#357, GEO).
  use KilnCMS.CMS.Content,
    type: :post,
    excerpt?: true,
    schema_org_type: "BlogPosting"
end
