defmodule KilnCMSWeb.ReleasePreviewLive do
  @moduledoc """
  The site **as of a release** (`/preview/release/:token`, #500 phase 2).

  Every document a release will publish, rendered exactly as go-live will render
  it, plus every document it will take down — one page a stakeholder can read
  end to end before signing off, opened from a short-lived signed link with no
  editor account required.

  Fidelity comes from sharing the delivery path rather than describing it: the
  same `KilnCMSWeb.BlockComponents` and `Layouts.public` shell the live site and
  the shared draft preview (`KilnCMSWeb.TokenPreviewLive`) use. See
  `KilnCMS.CMS.ReleasePreview` for why the overlay is a read of the live draft
  rows and not a version replay.

  An invalid, expired, or wrong-site token renders a dead-link notice — never
  content, and never a redirect target to probe. The tight `:preview` rate limit
  fronts the route.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ReleasePreview
  alias KilnCMSWeb.BlockComponents

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    with {:ok, %{release_id: id, org_id: org_id}} <- ReleasePreview.verify(token),
         :ok <- same_site(org_id, socket.assigns[:current_org]),
         {:ok, release} <- CMS.get_release(id, authorize?: false, tenant: org_id) do
      entries = ReleasePreview.overlay(release)

      {:ok,
       socket
       |> assign(:invalid?, false)
       |> assign(:release, release)
       |> assign(:page_title, gettext("Release preview: %{name}", name: release.name))
       |> assign(:publishing, Enum.filter(entries, &(&1.item.action == :publish)))
       |> assign(:removing, Enum.filter(entries, &(&1.item.action == :unpublish)))}
    else
      _ -> {:ok, dead_link(socket)}
    end
  end

  def mount(_params, _session, socket), do: {:ok, dead_link(socket)}

  defp dead_link(socket) do
    socket
    |> assign(:invalid?, true)
    |> assign(:page_title, gettext("Release preview"))
  end

  # A preview link forwarded to a different site's host would render one
  # tenant's unpublished content wrapped in another's branding (the trade #680
  # settled for single-record previews cuts the other way here, because a
  # release preview lists a whole campaign). Refuse rather than mislabel.
  defp same_site(org_id, %{id: org_id}), do: :ok
  defp same_site(_org_id, _org), do: :error

  defp blocks(record) do
    record.blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
    |> BlockComponents.thin_blocks()
  end

  defp anchor(entry), do: "release-item-#{entry.item.id}"

  defp go_live_label(%{scheduled_at: nil}), do: gettext("on manual trigger")

  defp go_live_label(%{scheduled_at: at}),
    do: gettext("scheduled for %{at} UTC", at: Calendar.strftime(at, "%Y-%m-%d %H:%M"))

  @impl true
  def render(%{invalid?: true} = assigns) do
    ~H"""
    <div class="mx-auto max-w-md px-6 py-24 text-center">
      <h1 class="text-xl font-semibold">{gettext("This preview link has expired")}</h1>
      <p class="mt-3 text-base-content/70">
        {gettext(
          "Release preview links are short-lived. Ask the editor who shared it for a fresh one."
        )}
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="sticky top-0 z-20 flex flex-wrap items-center justify-between gap-2 bg-warning/90 px-4 py-1.5 text-xs font-medium text-warning-content">
      <span>
        {gettext("Preview of release “%{name}” — not the live site", name: @release.name)}
      </span>
      <span>{go_live_label(@release)}</span>
    </div>

    <Layouts.public current_org={@current_org}>
      <div class="mx-auto max-w-3xl">
        <header class="mb-8">
          <h1 class="text-3xl font-bold tracking-tight">{@release.name}</h1>
          <p :if={@release.description} class="mt-2 text-base-content/70">{@release.description}</p>

          <p class="mt-4 text-sm text-base-content/70">
            {gettext("%{publishing} going live, %{removing} coming down.",
              publishing: length(@publishing),
              removing: length(@removing)
            )}
          </p>

          <nav :if={@publishing != []} class="mt-4" aria-label={gettext("Documents in this release")}>
            <ul class="space-y-1 text-sm">
              <li :for={entry <- @publishing}>
                <a href={"##{anchor(entry)}"} class="link">{entry.title}</a>
                <span class="ml-1 text-xs text-base-content/50">{entry.label}</span>
              </li>
            </ul>
          </nav>
        </header>

        <section :if={@removing != []} class="mb-10 rounded-lg border border-error/30 bg-error/5 p-4">
          <h2 class="text-sm font-semibold">{gettext("Coming off the site")}</h2>
          <ul class="mt-2 space-y-1 text-sm">
            <li :for={entry <- @removing} class="flex items-center gap-2">
              <span>{entry.title}</span>
              <span class="text-xs text-base-content/50">{entry.label}</span>
            </li>
          </ul>
        </section>

        <article
          :for={entry <- @publishing}
          id={anchor(entry)}
          class="mb-12 border-t border-base-content/10 pt-8 first:border-t-0 first:pt-0"
        >
          <p class="mb-2 text-xs uppercase tracking-wide text-base-content/50">{entry.label}</p>

          <%= if entry.record do %>
            <h2 class="text-2xl font-bold tracking-tight">{entry.title}</h2>
            <div class="prose mt-4 max-w-none">
              <BlockComponents.render_block :for={block <- blocks(entry.record)} block={block} />
            </div>
          <% else %>
            <h2 class="text-2xl font-bold tracking-tight">{entry.title}</h2>
            <p class="mt-4 rounded border border-error/30 bg-error/5 p-3 text-sm">
              {gettext("This content no longer exists — the release will not publish as it stands.")}
            </p>
          <% end %>
        </article>

        <p :if={@publishing == [] and @removing == []} class="text-base-content/70">
          {gettext("This release is empty.")}
        </p>
      </div>
    </Layouts.public>
    """
  end
end
