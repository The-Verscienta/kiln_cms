defmodule KilnCMSWeb.SiteStorageLive do
  @moduledoc """
  A site's own object storage (#1559): the S3-compatible bucket this site's
  new uploads go to, at `/editor/site-storage`.

  Before this, storage was `S3_*` environment variables — one bucket for the
  whole deployment. Now a site admin can keep their site's files in their own
  bucket, under their own account. The operator's storage stays underneath for
  every site that has not set one.

  Scoped to the request's org. Writes are policy-gated to org admins by
  `KilnCMS.CMS.SiteStorage`, and the `:admin_routes` live session gates on the
  same tier.

  ## What the page has to say

    * **Where new uploads go now**, and that changing it moves nothing: files
      already uploaded stay where they are and are still read from there
      (`KilnCMS.CMS.StorageProfile`). An admin who expects a switch to migrate
      the library would otherwise think it lost their files, or delete the old
      bucket.
    * **When the stored secret can't be read.** After a `SECRET_KEY_BASE`
      rotation the row still looks fine, but uploads are refused. This page is
      the one place that can say so.

  The secret field is write-only. It is never filled in, so a blank field
  keeps the stored secret (`Changes.StoreStorageSecret`).

  ## Testing

  "Test" writes, reads back and deletes a small object with what is *saved*
  (`KilnCMS.Storage.SiteProfiles.probe/1`). The handler re-asks the resource's
  update policy before touching the bucket instead of trusting the mount guard
  alone (#1166).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Storage.SiteProfiles

  @fields ~w(endpoint region bucket private_bucket public_base_url access_key_id)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Object storage"))
     |> assign(:testing?, false)
     |> assign(:test_result, nil)
     |> load()}
  end

  @impl true
  def handle_event("validate", %{"storage" => params}, socket) when is_map(params) do
    {:noreply,
     assign(socket, :form, to_form(Map.delete(params, "secret_access_key"), as: :storage))}
  end

  def handle_event("save", %{"storage" => params}, socket) when is_map(params) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    # An existing row is updated, never re-upserted — the same rule as the other
    # integrations' pages, so a create race cannot drop a new secret.
    result =
      case socket.assigns.row do
        nil -> CMS.save_site_storage(attrs(params), opts)
        row -> CMS.update_site_storage(row, attrs(params), opts)
      end

    case result do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Object storage saved."))
         |> assign(:test_result, nil)
         |> load()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.delete(params, "secret_access_key"), as: :storage))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    case socket.assigns.row do
      nil ->
        {:noreply, socket}

      row ->
        CMS.reset_site_storage!(row,
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "Removed. New uploads go to the deployment's storage again; files already in your bucket are still read from it."
           )
         )
         |> assign(:test_result, nil)
         |> load()}
    end
  end

  def handle_event("test", _params, socket) do
    %{row: row, current_user: user, current_org: org} = socket.assigns

    cond do
      socket.assigns.testing? or is_nil(row) or is_nil(row.profile_id) ->
        {:noreply, socket}

      # The probe writes to the bucket with the site's key and checks nothing
      # itself, so a forged event on a socket that never passed the mount
      # guard stops here (#1166).
      not CMS.can_update_site_storage?(user, row, tenant: org) ->
        {:noreply, socket}

      true ->
        org_id = KilnCMS.Accounts.org_id(org)
        profile_id = row.profile_id

        {:noreply,
         socket
         |> assign(:testing?, true)
         |> assign(:test_result, nil)
         |> start_async(:test, fn -> run_test(org_id, profile_id) end)}
    end
  end

  @impl true
  def handle_async(:test, {:ok, :ok}, socket) do
    {:noreply, socket |> assign(:testing?, false) |> assign(:test_result, :ok)}
  end

  def handle_async(:test, {:ok, {:error, message}}, socket) do
    {:noreply, socket |> assign(:testing?, false) |> assign(:test_result, {:error, message})}
  end

  def handle_async(:test, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:testing?, false)
     |> assign(:test_result, {:error, gettext("The test stopped unexpectedly.")})}
  end

  defp run_test(org_id, profile_id) do
    with {:ok, profile} <- SiteProfiles.fetch(org_id, profile_id),
         :ok <- SiteProfiles.probe(profile) do
      :ok
    else
      {:error, {step, detail}} when is_atom(step) and is_binary(detail) ->
        {:error, describe_step(step, detail)}

      {:error, reason} ->
        {:error, SiteProfiles.describe_error(reason)}
    end
  end

  defp describe_step(:write, detail),
    do: gettext("couldn't write a test file to the bucket (%{detail})", detail: detail)

  defp describe_step(:read, detail),
    do: gettext("couldn't read the test file back (%{detail})", detail: detail)

  defp describe_step(:delete, detail),
    do: gettext("couldn't delete the test file (%{detail})", detail: detail)

  defp describe_step(:private_write, detail),
    do: gettext("couldn't write a test file to the private bucket (%{detail})", detail: detail)

  defp describe_step(:private_read, detail),
    do:
      gettext("couldn't read the test file back from the private bucket (%{detail})",
        detail: detail
      )

  defp describe_step(:private_delete, detail),
    do:
      gettext("couldn't delete the test file from the private bucket (%{detail})",
        detail: detail
      )

  defp describe_step(_step, detail), do: detail

  defp attrs(params) do
    params
    |> Map.take(@fields)
    |> Map.put("enabled", params["enabled"] in [true, "true", "on"])
    |> Map.put("secret_access_key", params["secret_access_key"])
  end

  defp load(socket) do
    row = current_row(socket)
    profile = row && current_profile(socket, row.profile_id)

    params =
      if profile do
        %{
          "enabled" => row.enabled,
          "endpoint" => profile.endpoint,
          "region" => profile.region,
          "bucket" => profile.bucket,
          "private_bucket" => profile.private_bucket,
          "public_base_url" => profile.public_base_url,
          "access_key_id" => profile.access_key_id
        }
      else
        %{"enabled" => true, "region" => "us-east-1"}
      end

    socket
    |> assign(:row, row)
    |> assign(:profile, profile)
    |> assign(:secret_readable?, is_nil(profile) or SiteProfiles.secret_readable?(profile))
    |> assign(:form, to_form(params, as: :storage))
  end

  defp current_row(socket) do
    case CMS.list_site_storage(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  defp current_profile(_socket, nil), do: nil

  defp current_profile(socket, id) do
    case CMS.get_storage_profile(id,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, profile} -> profile
      _ -> nil
    end
  end

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's object storage."),
      fallback: gettext("Object storage could not be saved.")
    )
  end

  defp in_use?(%{row: %{enabled: true}, profile: %{}}), do: true
  defp in_use?(_assigns), do: false

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :in_use?, in_use?(assigns))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      active={:site_storage}
    >
      <.header>
        {gettext("Object storage")}
        <:subtitle>
          {gettext("The S3-compatible bucket this site's new uploads are stored in.")}
        </:subtitle>
      </.header>

      <div id="site-storage-status" class="mt-6 card card-pad text-sm">
        <p class="font-medium">
          <%= if @in_use? do %>
            {gettext("New uploads go to the bucket %{bucket}, served from %{url}.",
              bucket: @profile.bucket,
              url: @profile.public_base_url
            )}
          <% else %>
            {gettext("New uploads go to the deployment's storage.")}
          <% end %>
        </p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Changing this moves nothing. Files already uploaded stay where they were stored and are still read from there, so keep an old bucket and its key working until you have moved its files yourself."
          )}
        </p>
      </div>

      <div
        :if={not @secret_readable?}
        id="site-storage-secret-unreadable"
        role="alert"
        class="mt-4 rounded-lg border border-error/40 bg-error/10 p-4 text-sm text-error-ink"
      >
        <p class="font-medium">
          {gettext("The saved secret access key can't be read. Re-enter it.")}
        </p>
        <p class="mt-1">
          {gettext(
            "The deployment's secret key has changed since it was saved. Until you enter it again, uploads to this site are refused, and its files in this bucket can't be read."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id="site-storage-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 space-y-6"
      >
        <.input
          field={@form[:enabled]}
          type="checkbox"
          label={gettext("Store this site's new uploads in this bucket")}
          value={@form[:enabled].value}
        />

        <div class="grid gap-4 sm:grid-cols-3">
          <div class="sm:col-span-2">
            <.input
              field={@form[:endpoint]}
              type="url"
              label={gettext("Endpoint")}
              placeholder="https://<account>.r2.cloudflarestorage.com"
              autocomplete="off"
              hint={gettext("Leave blank for AWS S3.")}
            />
          </div>
          <.input
            field={@form[:region]}
            type="text"
            label={gettext("Region")}
            placeholder="us-east-1"
            autocomplete="off"
            hint={gettext("\"auto\" for Cloudflare R2.")}
          />
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:bucket]}
            type="text"
            label={gettext("Bucket")}
            autocomplete="off"
            hint={gettext("Public read, set on the bucket itself.")}
          />
          <.input
            field={@form[:private_bucket]}
            type="text"
            label={gettext("Private bucket")}
            autocomplete="off"
            hint={gettext("Optional. For members-only documents and direct uploads.")}
          />
        </div>

        <.input
          field={@form[:public_base_url]}
          type="url"
          label={gettext("Public URL")}
          placeholder="https://cdn.example.com/my-bucket"
          autocomplete="off"
          hint={
            gettext("Where the bucket's files are served from: a CDN or the bucket's public URL.")
          }
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:access_key_id]}
            type="text"
            label={gettext("Access key ID")}
            autocomplete="off"
          />
          <.input
            field={@form[:secret_access_key]}
            type="password"
            label={gettext("Secret access key")}
            value=""
            autocomplete="new-password"
            placeholder={if @profile, do: gettext("Saved. Leave blank to keep it.")}
            hint={gettext("Stored encrypted and never shown again.")}
          />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <.button
            :if={@profile}
            type="button"
            variant="ghost"
            id="site-storage-test"
            phx-click="test"
            disabled={@testing?}
          >
            {if @testing?, do: gettext("Testing…"), else: gettext("Test the saved bucket")}
          </.button>
          <.button
            :if={@row}
            type="button"
            variant="ghost"
            phx-click="reset"
            data-confirm={
              gettext(
                "Stop using this bucket for new uploads? Files already in it stay there and are still read from it."
              )
            }
          >
            {gettext("Remove")}
          </.button>
        </div>
      </.form>

      <div :if={@test_result} id="site-storage-test-result" role="status" class="mt-4 text-sm">
        <%= case @test_result do %>
          <% :ok -> %>
            <p class="text-success-ink">
              {gettext("The bucket works: a test file was written, read back and deleted.")}
            </p>
          <% {:error, message} -> %>
            <p class="text-error-ink">
              {gettext("The test failed: %{reason}", reason: message)}
            </p>
        <% end %>
      </div>
    </Layouts.console>
    """
  end
end
