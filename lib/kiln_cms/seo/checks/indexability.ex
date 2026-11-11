defmodule KilnCMS.Seo.Checks.Indexability do
  @moduledoc """
  A published page that the site's own navigation links to but that is told to
  stay out of search engines (#2256).

  Hiding a page from search is legitimate; hiding one the menu advertises is
  usually a flag left on by mistake, so this is a prompt to confirm rather
  than a defect: `:warning`, never blocking.

  ## Needs a fact

  Whether a menu links here is a query, and checks are pure. The editor
  computes `:nav_linked?` once and hands it in (see `Kiln.Advisory.Context`);
  a caller that did not is answered with `:n_a` rather than a guess. A draft
  is `:n_a` as well: nothing is published to be indexed yet, so an unlinked
  or linked draft says nothing about the live site.

  `nofollow` alone never fires. It does not remove the page from results.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  @impl Kiln.Advisory
  def lenses, do: [:seo]

  @impl Kiln.Advisory
  def check(%Context{} = context) do
    published? = Context.field(context, :state) == :published
    nav_linked? = Context.fact(context, :nav_linked?)

    cond do
      not published? -> [:n_a]
      is_nil(nav_linked?) -> [:n_a]
      nav_linked? and Context.field(context, :noindex) == true -> [indexed_but_linked()]
      true -> [:ok]
    end
  end

  defp indexed_but_linked, do: finding(:warning, :noindex_nav_linked, :noindex)
end
