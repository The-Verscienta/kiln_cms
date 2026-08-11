defmodule KilnCMS.CMS.Changes.ReverifyAppIcon do
  @moduledoc """
  Nightly re-check of a site's stored `app_icon_url` (#1147).

  On save, `KilnCMS.Branding.AppIcon.verify/1` runs once and the measured edge
  is stored. Nothing else re-ran it, so a URL that later 404s kept a size and
  every gate still treated the icon as usable — fine for the manifest (stock
  icons stay alongside), bad for `apple-touch-icon` (a single href with no
  fallback).

  This change is what the AshOban `:reverify_app_icon` trigger runs per row:

    * success → write the (possibly updated) edge, clear the failure streak;
    * failure → bump the streak; only after
      `KilnCMS.CMS.SiteBranding.app_icon_failure_threshold/0` consecutive
      failures clear **the size**, never the URL.

  Clearing the URL on a transient CDN outage would discard what the operator
  typed; clearing the size alone restores the stock icon until the next
  successful verify. The threshold exists for the same reason: one bad night
  must not yank a working icon.
  """
  use Ash.Resource.Change

  alias KilnCMS.Branding.AppIcon
  alias KilnCMS.CMS.SiteBranding

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    url = changeset.data.app_icon_url

    case AppIcon.verify(url) do
      {:ok, edge} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:app_icon_size, edge)
        |> Ash.Changeset.force_change_attribute(:app_icon_verify_failures, 0)

      {:error, reason} ->
        failures = (changeset.data.app_icon_verify_failures || 0) + 1
        threshold = SiteBranding.app_icon_failure_threshold()

        Logger.info(
          "App icon re-verify for org #{changeset.data.org_id} failed " <>
            "(#{failures}/#{threshold}): #{inspect(reason)}"
        )

        changeset
        |> maybe_clear_size(failures, threshold)
        |> Ash.Changeset.force_change_attribute(:app_icon_verify_failures, failures)
    end
  end

  defp maybe_clear_size(changeset, failures, threshold) when failures >= threshold do
    Ash.Changeset.force_change_attribute(changeset, :app_icon_size, nil)
  end

  defp maybe_clear_size(changeset, _failures, _threshold), do: changeset
end
