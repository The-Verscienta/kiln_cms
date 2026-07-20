defmodule KilnCMSWeb.NewsletterLive do
  @moduledoc """
  Newsletter admin (`/editor/newsletter`) — manage subscriber segments and the
  subscriber list, send a published post to a segment via the built-in MTA, and
  review campaign history. Admin-only (issue #337, Phase 1).
  """
  use KilnCMSWeb, :live_view

  require Ash.Query

  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.Segment
  alias KilnCMS.Newsletter.Subscriber

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Newsletter"))
       |> assign(:segment_form, segment_form(actor, org))
       |> assign(:subscriber_form, subscriber_form(actor, org))
       |> assign(:send_params, %{"post_id" => "", "segment_id" => "", "subject" => ""})
       |> load_segments()
       |> load_subscribers()
       |> load_posts()
       |> load_sends()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- segments --------------------------------------------------------------

  @impl true
  def handle_event("validate_segment", %{"segment" => params}, socket) do
    {:noreply,
     assign(socket, :segment_form, AshPhoenix.Form.validate(socket.assigns.segment_form, params))}
  end

  def handle_event("create_segment", %{"segment" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.segment_form, params: params) do
      {:ok, _segment} ->
        {:noreply,
         socket
         |> assign(:segment_form, segment_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_segments()
         |> put_flash(:info, gettext("Segment created."))}

      {:error, form} ->
        {:noreply, assign(socket, :segment_form, form)}
    end
  end

  def handle_event("delete_segment", %{"id" => id}, socket) do
    org = socket.assigns.current_org

    socket =
      with {:ok, segment} <- Newsletter.get_segment(id, actor: socket.assigns.actor, tenant: org),
           :ok <- Newsletter.destroy_segment(segment, actor: socket.assigns.actor, tenant: org) do
        socket |> load_segments() |> load_posts() |> put_flash(:info, gettext("Segment deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that segment."))
      end

    {:noreply, socket}
  end

  # --- subscribers -----------------------------------------------------------

  def handle_event("validate_subscriber", %{"subscriber" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :subscriber_form,
       AshPhoenix.Form.validate(socket.assigns.subscriber_form, params)
     )}
  end

  def handle_event("add_subscriber", %{"subscriber" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.subscriber_form, params: params) do
      {:ok, _subscriber} ->
        {:noreply,
         socket
         |> assign(
           :subscriber_form,
           subscriber_form(socket.assigns.actor, socket.assigns.current_org)
         )
         |> load_subscribers()
         |> put_flash(:info, gettext("Subscriber added (pending confirmation)."))}

      {:error, form} ->
        {:noreply, assign(socket, :subscriber_form, form)}
    end
  end

  def handle_event("confirm_subscriber", %{"id" => id}, socket) do
    org = socket.assigns.current_org

    socket =
      with {:ok, subscriber} <-
             Newsletter.get_subscriber(id, actor: socket.assigns.actor, tenant: org),
           {:ok, _} <-
             Newsletter.confirm_subscriber(subscriber, actor: socket.assigns.actor, tenant: org) do
        socket |> load_subscribers() |> put_flash(:info, gettext("Subscriber confirmed."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't confirm that subscriber."))
      end

    {:noreply, socket}
  end

  def handle_event("remove_subscriber", %{"id" => id}, socket) do
    org = socket.assigns.current_org

    socket =
      with {:ok, subscriber} <-
             Newsletter.get_subscriber(id, actor: socket.assigns.actor, tenant: org),
           :ok <- Ash.destroy(subscriber, actor: socket.assigns.actor, tenant: org) do
        socket |> load_subscribers() |> put_flash(:info, gettext("Subscriber removed."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't remove that subscriber."))
      end

    {:noreply, socket}
  end

  # --- send ------------------------------------------------------------------

  def handle_event("send", %{"send" => params}, socket) do
    post = Enum.find(socket.assigns.posts, &(&1.id == params["post_id"]))
    segment_id = presence(params["segment_id"])
    subject = presence(params["subject"])

    socket =
      if is_nil(post) do
        put_flash(socket, :error, gettext("Choose a published post to send."))
      else
        opts =
          [segment_id: segment_id, actor: socket.assigns.actor]
          |> maybe_put(:subject, subject)

        case Newsletter.send_as_newsletter(post, opts) do
          {:ok, _send} ->
            socket
            |> assign(:send_params, %{"post_id" => "", "segment_id" => "", "subject" => ""})
            |> load_sends()
            |> put_flash(:info, gettext("Newsletter queued for delivery."))

          {:error, reason} ->
            put_flash(socket, :error, send_error(reason))
        end
      end

    {:noreply, socket}
  end

  defp send_error(:gated),
    do: gettext("That post has a restricted audience and can't be sent to a public list.")

  defp send_error(:not_published), do: gettext("Only published posts can be sent.")

  defp send_error(:not_fired),
    do: gettext("That post hasn't been fired yet — republish it and retry.")

  defp send_error(:already_sent),
    do: gettext("A campaign for this publish revision was already sent.")

  # Ledger/validation failures (e.g. a bad segment) surface as Ash errors —
  # show a generic failure rather than crashing the LiveView.
  defp send_error(_other), do: gettext("The campaign couldn't be recorded — check the details.")

  # --- data ------------------------------------------------------------------

  defp load_segments(socket) do
    assign(
      socket,
      :segments,
      Newsletter.list_segments!(actor: socket.assigns.actor, tenant: socket.assigns.current_org)
    )
  end

  defp load_subscribers(socket) do
    subscribers =
      Subscriber
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: socket.assigns.actor, tenant: socket.assigns.current_org)

    socket
    |> assign(:subscribers, subscribers)
    |> assign(:confirmed_count, Enum.count(subscribers, &(&1.status == :confirmed)))
  end

  # Only published, world-readable posts can be newslettered (gated/embargoed
  # content is excluded up front, mirroring the dispatch guard).
  defp load_posts(socket) do
    posts =
      KilnCMS.CMS.Post
      |> Ash.Query.filter(state == :published and audience == :public)
      |> Ash.Query.sort(published_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: socket.assigns.actor, tenant: socket.assigns.current_org)

    assign(socket, :posts, posts)
  end

  defp load_sends(socket) do
    assign(
      socket,
      :sends,
      Newsletter.recent_sends!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        load: [:segment]
      )
    )
  end

  defp segment_form(actor, org) do
    Segment
    |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: "segment")
    |> to_form()
  end

  defp subscriber_form(actor, org) do
    Subscriber
    |> AshPhoenix.Form.for_create(:subscribe, actor: actor, tenant: org, as: "subscriber")
    |> to_form()
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:newsletter}
    >
      <div class="space-y-10">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Newsletter")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("Send a published post to your subscribers via the built-in mail server.")}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Send a newsletter")}</h2>
          <form phx-submit="send" class="card card-pad space-y-4">
            <label class="block">
              <span class="text-sm font-medium">{gettext("Published post")}</span>
              <select name="send[post_id]" class="select select-bordered mt-1 w-full" required>
                <option value="">{gettext("Choose a post…")}</option>
                <option
                  :for={post <- @posts}
                  value={post.id}
                  selected={@send_params["post_id"] == post.id}
                >
                  {post.title}
                </option>
              </select>
              <span :if={@posts == []} class="mt-1 block text-xs text-base-content/60">
                {gettext("No published, public posts available to send.")}
              </span>
            </label>

            <label class="block">
              <span class="text-sm font-medium">{gettext("Segment")}</span>
              <select name="send[segment_id]" class="select select-bordered mt-1 w-full">
                <option value="">{gettext("All confirmed subscribers")}</option>
                <option :for={segment <- @segments} value={segment.id}>{segment.name}</option>
              </select>
            </label>

            <.input
              type="text"
              name="send[subject]"
              value={@send_params["subject"]}
              label={gettext("Subject (optional — defaults to the post title)")}
            />

            <.button type="submit" variant="primary">{gettext("Send newsletter")}</.button>
          </form>
        </section>

        <section class="grid gap-8 lg:grid-cols-2">
          <div class="space-y-4">
            <h2 class="text-lg font-medium">{gettext("Segments")} ({length(@segments)})</h2>
            <.form
              for={@segment_form}
              id="segment-form"
              phx-change="validate_segment"
              phx-submit="create_segment"
              class="card card-pad space-y-3"
            >
              <.input field={@segment_form[:name]} label={gettext("Name")} />
              <.input field={@segment_form[:slug]} label={gettext("Slug")} />
              <.button type="submit" variant="primary">{gettext("Add segment")}</.button>
            </.form>

            <ul :if={@segments != []} class="card divide-y divide-base-content/10 overflow-hidden">
              <li :for={segment <- @segments} class="flex items-center justify-between p-3">
                <div>
                  <span class="text-sm font-medium">{segment.name}</span>
                  <code class="ml-2 text-xs text-base-content/60">{segment.slug}</code>
                </div>
                <button
                  type="button"
                  phx-click="delete_segment"
                  phx-value-id={segment.id}
                  data-confirm={gettext("Delete this segment?")}
                  class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </li>
            </ul>
          </div>

          <div class="space-y-4">
            <h2 class="text-lg font-medium">
              {gettext("Subscribers")} ({@confirmed_count} {gettext("confirmed")})
            </h2>
            <.form
              for={@subscriber_form}
              id="subscriber-form"
              phx-change="validate_subscriber"
              phx-submit="add_subscriber"
              class="card card-pad space-y-3"
            >
              <.input field={@subscriber_form[:email]} type="email" label={gettext("Email")} />
              <.input field={@subscriber_form[:name]} label={gettext("Name (optional)")} />
              <.button type="submit" variant="primary">{gettext("Add subscriber")}</.button>
            </.form>

            <ul :if={@subscribers != []} class="card divide-y divide-base-content/10 overflow-hidden">
              <li
                :for={subscriber <- @subscribers}
                class="flex items-center justify-between gap-2 p-3"
              >
                <div class="min-w-0">
                  <code class="truncate text-xs">{subscriber.email}</code>
                  <span class={[
                    "ml-2 rounded px-1.5 py-0.5 text-xs font-medium",
                    subscriber.status == :confirmed && "bg-success/15 text-success",
                    subscriber.status == :pending && "bg-warning/15 text-warning",
                    subscriber.status == :unsubscribed && "bg-base-200 text-base-content/60"
                  ]}>
                    {subscriber.status}
                  </span>
                </div>
                <div class="flex shrink-0 gap-1">
                  <button
                    :if={subscriber.status == :pending}
                    type="button"
                    phx-click="confirm_subscriber"
                    phx-value-id={subscriber.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Confirm")}
                  </button>
                  <button
                    type="button"
                    phx-click="remove_subscriber"
                    phx-value-id={subscriber.id}
                    data-confirm={gettext("Remove this subscriber?")}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Recent campaigns")}</h2>
          <p :if={@sends == []} class="text-sm text-base-content/60">
            {gettext("No campaigns yet.")}
          </p>

          <div :if={@sends != []} class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("When")}</th>
                  <th>{gettext("Subject")}</th>
                  <th>{gettext("Segment")}</th>
                  <th>{gettext("Status")}</th>
                  <th>{gettext("Sent")}</th>
                  <th>{gettext("Failed")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={send <- @sends}>
                  <td class="whitespace-nowrap text-base-content/70">
                    {Calendar.strftime(send.inserted_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td class="max-w-56 truncate">{send.subject}</td>
                  <td class="text-base-content/70">
                    {(send.segment && send.segment.name) || gettext("All")}
                  </td>
                  <td>{send.status}</td>
                  <td>{send.sent_count}/{send.total_recipients}</td>
                  <td>{send.failed_count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
