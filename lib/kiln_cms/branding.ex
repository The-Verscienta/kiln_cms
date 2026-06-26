defmodule KilnCMS.Branding do
  @moduledoc """
  White-label branding tokens — site name, logo, and an optional primary brand
  colour — read from config so an agency/white-label deployment can rebrand the
  public and editor chrome without code changes:

      config :kiln_cms, :branding,
        site_name: "Acme CMS",
        logo_url: "/images/acme-logo.svg",
        primary_color: "oklch(55% 0.2 264)"

  Override at runtime via `SITE_NAME`, `BRAND_LOGO_URL`, and
  `BRAND_PRIMARY_COLOR` (see `config/runtime.exs`). All tokens have safe
  defaults, so an unconfigured deployment renders as stock KilnCMS.
  """
  @default_site_name "KilnCMS"
  @default_logo_url "/images/logo.svg"

  @doc "Brand/site name shown in the header and the page-title suffix."
  @spec site_name() :: String.t()
  def site_name, do: config(:site_name) || @default_site_name

  @doc "Header logo URL (a static path or absolute URL)."
  @spec logo_url() :: String.t()
  def logo_url, do: config(:logo_url) || @default_logo_url

  @doc "Configured primary brand colour (any CSS colour), or nil."
  @spec primary_color() :: String.t() | nil
  def primary_color do
    case config(:primary_color) do
      "" -> nil
      color -> color
    end
  end

  @doc """
  Inline `style` value that overrides the primary theme colour for the whole
  document, or `nil` when no brand colour is configured. Applied on the `<html>`
  element; `style-src 'unsafe-inline'` already permits inline `style` attributes.
  """
  @spec primary_color_style() :: String.t() | nil
  def primary_color_style do
    case primary_color() do
      nil -> nil
      color -> "--color-primary: #{color};"
    end
  end

  defp config(key), do: :kiln_cms |> Application.get_env(:branding, []) |> Keyword.get(key)
end
