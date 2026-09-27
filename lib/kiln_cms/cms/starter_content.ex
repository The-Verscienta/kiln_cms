defmodule KilnCMS.CMS.StarterContent do
  @moduledoc """
  The content a fresh site starts with: one draft Home page (slug `home`).

  A new install used to end `/setup` with nothing to edit and a site root
  that advertised Kiln itself. The starter page closes that gap — the
  operator lands on something to rewrite, and once it is published the site
  root serves it (`KilnCMSWeb.PageController.home/2`) instead of the stock
  template.

  It is created as a **draft**, never published: what a visitor sees first is
  the operator's decision, not ours. Every write runs as the given actor with
  authorization on — there is no system bypass here.
  """

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @home_slug "home"

  @doc "The slug the site root serves once a page with it is published."
  @spec home_slug() :: String.t()
  def home_slug, do: @home_slug

  @doc """
  The site's Home page (any state), or `nil`. Reads as `actor`, so it answers
  only what that actor may see.
  """
  @spec home_page(term(), term()) :: Page.t() | nil
  def home_page(actor, tenant) do
    Page
    |> Ash.Query.filter(slug == ^@home_slug)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor, tenant: tenant)
  end

  @doc """
  Whether `org_id` has a **published** Home page — a system read, because the
  site root asks it for anonymous visitors. It reads existence only; delivery
  itself (audience, passphrase, locale) stays with `ContentController`.
  """
  @spec published_home?(String.t()) :: boolean()
  def published_home?(org_id) do
    Page
    |> Ash.Query.filter(slug == ^@home_slug and state == :published)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> Enum.any?()
  end

  @doc """
  Create the starter Home page as a draft unless the site already has one.

  Options: `:site_name` — used for the page's heading when given.
  """
  @spec ensure_home_page(term(), term(), keyword()) ::
          {:ok, Page.t()} | {:error, term()}
  def ensure_home_page(actor, tenant, opts \\ []) do
    case home_page(actor, tenant) do
      nil -> CMS.create_page(home_attrs(opts[:site_name]), actor: actor, tenant: tenant)
      page -> {:ok, page}
    end
  end

  defp home_attrs(site_name) do
    heading = site_name || "Welcome"

    %{
      title: "Home",
      slug: @home_slug,
      # Typed blocks with Portable Text prose: the legacy `%{type:, content:}`
      # params this used to pass stored the prose in the deprecated
      # `legacy_html` on every new site (#1537).
      blocks: [
        %{"_type" => "heading", "text" => heading, "level" => 1},
        %{
          "_type" => "rich_text",
          "body" =>
            KilnCMS.Blocks.PortableText.from_html(
              "<p>This is your home page. Replace this text with a welcome for your visitors, then publish it — it becomes the first thing people see at your site's address.</p>"
            )
        }
      ]
    }
  end
end
