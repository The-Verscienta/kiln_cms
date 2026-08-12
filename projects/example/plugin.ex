defmodule Example.Plugin do
  @moduledoc """
  The holistic-acupuncture site's **plugin** (decision D18). Everything the
  site layers on the core flows through the standard plugin seams and domain
  registration:

    * `Example.Catalog` — the content domain (conditions, team members,
      testimonials, FAQs), all built on `KilnCMS.CMS.Content`. Domains are
      declared here for `mix kiln.plugins.doctor` verification, and registered
      in the host config (`:ash_domains` + `:content_domains`), which is what
      actually activates them — the reusable core ships with this plugin
      dormant.
    * `priv/repo/example_field_definitions.exs` /
      `priv/repo/example_import.exs` (under `projects/example/`) — the
      one-time Sanity migration: custom-field definitions, then the content
      import (plain scripts run with `mix run`; they need no plugin callbacks).

  Activate in a deployment's config (see `projects/example/project.exs`):

      config :kiln_cms,
        plugins: [Example.Plugin],
        ash_domains: [..., Example.Catalog],
        content_domains: [KilnCMS.CMS, Example.Catalog]
  """
  use Kiln.Plugin

  @impl true
  def name, do: "example"

  @impl true
  def domains, do: [Example.Catalog]
end
