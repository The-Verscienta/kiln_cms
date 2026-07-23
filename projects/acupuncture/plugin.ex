defmodule Acupuncture.Plugin do
  @moduledoc """
  The holistic-acupuncture site's **plugin** (decision D18). Everything the
  site layers on the core flows through the standard plugin seams and domain
  registration:

    * `Acupuncture.Catalog` — the content domain (conditions, team members,
      testimonials, FAQs), all built on `KilnCMS.CMS.Content`. Domains are
      declared here for `mix kiln.plugins.doctor` verification, and registered
      in the host config (`:ash_domains` + `:content_domains`), which is what
      actually activates them — the reusable core ships with this plugin
      dormant.
    * `priv/repo/acupuncture_field_definitions.exs` /
      `priv/repo/acupuncture_import.exs` (under `projects/acupuncture/`) — the
      one-time Sanity migration: custom-field definitions, then the content
      import (plain scripts run with `mix run`; they need no plugin callbacks).

  Activate in a deployment's config (see `projects/acupuncture/project.exs`):

      config :kiln_cms,
        plugins: [Acupuncture.Plugin],
        ash_domains: [..., Acupuncture.Catalog],
        content_domains: [KilnCMS.CMS, Acupuncture.Catalog]
  """
  use Kiln.Plugin

  @impl true
  def name, do: "acupuncture"

  @impl true
  def domains, do: [Acupuncture.Catalog]
end
