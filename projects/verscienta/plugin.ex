defmodule Verscienta.Plugin do
  @moduledoc """
  The Verscienta Health **plugin** (decision D18) — the project the plan
  always described as *"the first plugin/consumer, not a coupling"*, now
  literally one.

  Everything Verscienta layers on the core flows through the standard plugin
  seams and domain registration:

    * `Verscienta.Catalog` — the content domain (herbs, formulas, conditions,
      practitioners, clinics, modalities), all built on `KilnCMS.CMS.Content`.
      Domains are declared here for `mix kiln.plugins.doctor` verification,
      and registered in the host config (`:ash_domains` + `:content_domains`),
      which is what actually activates them — the reusable core ships with
      this plugin dormant.
    * `mix verscienta.import` — the Directus migration pipeline (mix tasks
      need no plugin callbacks; they're discovered by Mix).

  Activate in a deployment's config:

      config :kiln_cms,
        plugins: [Verscienta.Plugin],
        ash_domains: [..., Verscienta.Catalog],
        content_domains: [KilnCMS.CMS, Verscienta.Catalog]
  """
  use Kiln.Plugin

  @impl true
  def name, do: "verscienta"

  @impl true
  def domains, do: [Verscienta.Catalog]
end
