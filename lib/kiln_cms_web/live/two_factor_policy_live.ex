defmodule KilnCMSWeb.TwoFactorPolicyLive do
  @moduledoc """
  This site's two-step sign-in requirement (`/editor/two-factor`, #2247): who
  must hold a second factor (nobody, administrators, editors and
  administrators, or everyone) and how long a covered account has to set one
  up.

  Scoped to the request's org like `/editor/sessions`, in the `:admin_routes`
  live session whose tier gate agrees with the resource's policy
  (`KilnCMS.CMS.SiteSecondFactorPolicy`): an admin of another site is
  refused at mount, and by the resource on any write. Not exempt from
  `KilnCMSWeb.SecondFactorGate`: an administrator the requirement holds must
  set up their own factor before they can reach the setting that would
  release them, or a password-only session could switch it off.

  ## Saving needs a second factor, now

  Every save goes through `KilnCMS.CMS.Changes.SaverVerifiedSecondFactor`:
  the administrator must hold a second factor and prove it now. This page
  passes the session's verified mark (`KilnCMSWeb.SignInMarker`'s
  `second_factor_at`, read once at mount and only while it belongs to the
  session's current token) as `second_factor_verified_at`, and the guard
  decides whether it is fresh. Without a fresh mark the form asks for a code
  from the authenticator app. The code is passed **only on submit**: the guard
  charges the second-factor budget every time a changeset is built with one,
  so the preview never builds a changeset.

  ## What it shows

    * the people the current policy covers, per tier: how many, how many hold
      a factor, how many are in their grace period and how many are held —
      counts only, never names (the roster is read without authorization and
      only counts and deadlines leave it);
    * a preview of the choice on the form, before saving: how many people
      would be asked to set a factor up, and how many of them at once;
    * the last change, from the policy row and its `second_factor_policy_changed`
      event (the security log lists the event but not what changed);
    * the server operator's way back in when no administrator can pass the
      requirement (`KilnCMS.Release.second_factor_requirement_off/1`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.TwoFactorRequirement.Policy
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.SaverVerifiedSecondFactor
  alias KilnCMS.CMS.SiteSecondFactorPolicy
  alias KilnCMSWeb.TotpEnrolment

  @grace_presets [0, 7, 14, 30, 90]
  @choices [:off, :admins, :editors, :everyone]

  @impl true
  def mount(_params, session, socket) do
    verified_at =
      case KilnCMSWeb.SignInMarker.read(session) do
        %{second_factor_at: %DateTime{} = at} -> at
        _none -> nil
      end

    {:ok,
     socket
     |> assign(:page_title, gettext("Two-step sign-in"))
     |> assign(:verified_at, verified_at)
     |> assign(:enrolled?, Accounts.has_second_factor?(socket.assigns.current_user))
     |> assign(:code_error, nil)
     |> load()}
  end

  @impl true
  # Typing the confirmation code changes nothing the preview shows, and each
  # preview reads the whole roster: a keystroke there is not a preview.
  def handle_event("preview", %{"_target" => ["policy", "code"]}, socket),
    do: {:noreply, socket}

  def handle_event("preview", %{"policy" => params}, socket) when is_map(params) do
    # The roster is read without authorization, so the caller is re-checked
    # against the row's own read policy (admins of this site) on every event:
    # a page opened before a demotion must not keep answering.
    with true <- may_read?(socket),
         {:ok, required_for, grace_days} <- parse(params) do
      {:noreply,
       socket
       |> assign(:form, form(required_for, grace_days))
       |> assign(:preview, preview(socket, required_for, grace_days))}
    else
      _refused_or_invalid -> {:noreply, socket}
    end
  end

  def handle_event("preview", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"policy" => params}, socket) when is_map(params) do
    with {:ok, required_for, grace_days} <- parse(params),
         {:ok, _row} <-
           CMS.save_site_second_factor_policy(
             code_argument(params, %{required_for: required_for, grace_days: grace_days}),
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org,
             context: save_context(socket)
           ) do
      {:noreply,
       socket
       |> assign(:code_error, nil)
       |> put_flash(:info, gettext("Two-step sign-in settings saved."))
       |> load()}
    else
      :invalid ->
        {:noreply, put_flash(socket, :error, gettext("Choose one of the listed options."))}

      {:error, error} ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # The code goes to the action only when one was typed, on this submit.
  defp code_argument(%{"code" => code}, attrs) when is_binary(code) do
    case String.trim(code) do
      "" -> attrs
      code -> Map.put(attrs, :code, code)
    end
  end

  defp code_argument(_params, attrs), do: attrs

  # What the guard is told about this session: the client the write is logged
  # with (#2241) and, when the session verified a second factor, when.
  defp save_context(socket) do
    case socket.assigns.verified_at do
      %DateTime{} = at -> Map.put(socket.assigns.security_context, :second_factor_verified_at, at)
      nil -> socket.assigns.security_context
    end
  end

  defp refused(socket, error) do
    messages = SaverVerifiedSecondFactor.messages()

    case guard_refusal(error, messages) do
      :not_enrolled ->
        put_flash(socket, :error, not_enrolled_message())

      reason when reason in [:not_verified, :wrong_code] ->
        socket
        |> assign(:needs_code?, true)
        |> assign(:code_error, code_message(reason))

      nil ->
        put_flash(
          socket,
          :error,
          TotpEnrolment.error_message(
            error,
            ash_error_message(error,
              forbidden:
                gettext("You don't have permission to change this site's two-step sign-in."),
              fallback: gettext("The two-step sign-in settings could not be saved.")
            )
          )
        )
    end
  end

  # Which of the guard's refusals this is, by its message (the guard's errors
  # are field errors on `:code`, in English; this page says them in the
  # reader's language).
  defp guard_refusal(%{errors: errors}, messages) do
    reasons = Map.new(messages, fn {reason, text} -> {text, reason} end)

    Enum.find_value(List.wrap(errors), fn
      %{field: :code, message: message} -> Map.get(reasons, message)
      _other -> nil
    end)
  end

  defp guard_refusal(_error, _messages), do: nil

  defp not_enrolled_message,
    do: gettext("Set up two-step sign-in on your own account first.")

  defp code_message(:not_verified),
    do:
      gettext(
        "Confirm with a code from your authenticator app, or sign in again with your passkey."
      )

  defp code_message(:wrong_code),
    do: gettext("That code isn't valid. Check your authenticator app.")

  # --- reading -----------------------------------------------------------------

  defp load(socket) do
    row = current_row(socket)
    policy = TwoFactorRequirement.from_row(row)
    now = DateTime.utc_now()

    socket
    |> assign(:row, row)
    |> assign(:policy, policy)
    |> assign(:roster, TwoFactorRequirement.roster(org_id(socket), policy, now: now))
    |> assign(:last_change, last_change(socket, row))
    |> assign(:needs_code?, not fresh?(socket.assigns.verified_at, now))
    |> assign(:form, form(policy.required_for, policy.grace_days))
    |> assign(:preview, nil)
  end

  defp current_row(socket) do
    case CMS.list_site_second_factor_policy(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _none -> nil
    end
  end

  defp may_read?(socket) do
    match?(
      {:ok, _rows},
      CMS.list_site_second_factor_policy(
        actor: socket.assigns.current_user,
        tenant: socket.assigns.current_org,
        authorize_with: :error
      )
    )
  end

  # The newest `second_factor_policy_changed` event: who changed it and from
  # what. `nil` when there is none, or the log can't be read.
  defp last_change(_socket, nil), do: nil

  defp last_change(socket, row) do
    event =
      case KilnCMS.Security.list_events(%{type: :second_factor_policy_changed},
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org,
             page: [limit: 1]
           ) do
        {:ok, %{results: [event | _]}} -> event
        {:ok, [event | _]} -> event
        _none -> nil
      end

    %{at: row.policy_changed_at || row.updated_at, event: event}
  end

  # Whether the session's mark is fresh enough that the guard will take it,
  # so the page knows to ask for a code up front. The guard decides again.
  defp fresh?(%DateTime{} = at, now),
    do: DateTime.diff(now, at, :second) <= SaverVerifiedSecondFactor.fresh_seconds()

  defp fresh?(nil, _now), do: false

  defp parse(params) do
    with {:ok, required_for} <- parse_choice(params["required_for"]),
         {:ok, grace_days} <- parse_grace(params["grace_days"]) do
      {:ok, required_for, grace_days}
    end
  end

  defp parse_choice(value) when is_binary(value) do
    case Enum.find(@choices, &(Atom.to_string(&1) == value)) do
      nil -> :invalid
      choice -> {:ok, choice}
    end
  end

  defp parse_choice(_value), do: :invalid

  defp parse_grace(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days >= 0 ->
        if days <= SiteSecondFactorPolicy.max_grace_days(), do: {:ok, days}, else: :invalid

      _other ->
        :invalid
    end
  end

  defp parse_grace(_value), do: :invalid

  defp form(required_for, grace_days) do
    to_form(
      %{"required_for" => Atom.to_string(required_for), "grace_days" => to_string(grace_days)},
      as: :policy
    )
  end

  # Who the choice on the form would ask to set a factor up, and how many at
  # once, were it saved now. The stamps are the ones a save would write
  # (`KilnCMS.CMS.Changes.StampSecondFactorRequirement`): a tier that stays
  # covered keeps its own, a newly covered one starts now.
  defp preview(socket, required_for, grace_days) do
    now = DateTime.utc_now()
    current = socket.assigns.policy
    covered = SiteSecondFactorPolicy.covered_tiers(required_for)

    since =
      Map.new(SiteSecondFactorPolicy.tiers(), fn tier ->
        cond do
          tier not in covered -> {tier, nil}
          TwoFactorRequirement.covers?(current, tier) -> {tier, current.since[tier] || now}
          true -> {tier, now}
        end
      end)

    candidate = %Policy{required_for: required_for, grace_days: grace_days, since: since}
    roster = TwoFactorRequirement.roster(org_id(socket), candidate, now: now)

    %{
      asked: roster |> Map.values() |> Enum.map(&(&1.in_grace + &1.overdue)) |> Enum.sum(),
      now: roster |> Map.values() |> Enum.map(& &1.overdue) |> Enum.sum()
    }
  end

  defp org_id(socket), do: socket.assigns.current_org.id

  # --- rendering ---------------------------------------------------------------

  defp choice_label(:off), do: gettext("Off")
  defp choice_label(:admins), do: gettext("Administrators")
  defp choice_label(:editors), do: gettext("Editors and administrators")
  defp choice_label(:everyone), do: gettext("Everyone")

  defp choice_help(:off), do: gettext("Nobody has to set up a second factor.")
  defp choice_help(:admins), do: gettext("People who can change this site's settings.")

  defp choice_help(:editors),
    do: gettext("Everyone who can edit content, and the administrators.")

  defp choice_help(:everyone), do: gettext("Every signed-in account, readers included.")

  defp tier_label(:admin), do: gettext("Administrators")
  defp tier_label(:editor), do: gettext("Editors")
  defp tier_label(:viewer), do: gettext("Viewers")

  defp grace_options(current) do
    presets =
      if current in @grace_presets,
        do: @grace_presets,
        else: Enum.sort([current | @grace_presets])

    Enum.map(presets, &{grace_label(&1), Integer.to_string(&1)})
  end

  defp grace_label(0), do: gettext("None: right away")
  defp grace_label(days), do: ngettext("%{count} day", "%{count} days", days)

  defp on_date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp who(%{metadata: %{"via" => "console"}}), do: gettext("the server operator")
  defp who(%{actor_label: label}) when is_binary(label) and label != "", do: label
  defp who(_event), do: gettext("an administrator")

  defp previous_label(%{metadata: %{"previous_required_for" => previous}}) do
    case Enum.find(@choices, &(Atom.to_string(&1) == previous)) do
      nil -> nil
      choice -> choice_label(choice)
    end
  end

  defp previous_label(_event), do: nil

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:choices, @choices)
      |> assign(:selected, assigns.form[:required_for].value)
      |> assign(:grace_options, grace_options(assigns.policy.grace_days))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:second_factor_policy}
    >
      <.header>
        {gettext("Two-step sign-in")}
        <:subtitle>
          {gettext(
            "Require people on this site to set up a second factor (an authenticator app or a passkey), and give them time to do it."
          )}
        </:subtitle>
      </.header>

      <div
        :if={!@enrolled?}
        id="two-factor-policy-not-enrolled"
        role="status"
        class="mt-6 max-w-2xl rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
      >
        <p class="font-medium">{not_enrolled_message()}</p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Changing this setting needs your own second factor, so that a stolen password alone can't turn it off."
          )}
        </p>
        <.link navigate={~p"/account/two-factor"} class="btn btn-sm btn-primary mt-3">
          {gettext("Set up two-step sign-in")}
        </.link>
      </div>

      <section id="two-factor-policy-roster" class="mt-8 max-w-2xl">
        <h2 class="text-lg font-medium">{gettext("Who it covers now")}</h2>
        <p :if={@roster == %{}} class="mt-1 text-sm text-base-content/70">
          {gettext("Two-step sign-in is optional on this site.")}
        </p>
        <table :if={@roster != %{}} class="mt-3 w-full text-sm">
          <thead>
            <tr class="text-left text-xs text-base-content/70">
              <th class="py-1 font-medium">{gettext("Role")}</th>
              <th class="py-1 font-medium">{gettext("People")}</th>
              <th class="py-1 font-medium">{gettext("Set up")}</th>
              <th class="py-1 font-medium">{gettext("Still in grace")}</th>
              <th class="py-1 font-medium">{gettext("Held until set up")}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/10">
            <tr
              :for={tier <- SiteSecondFactorPolicy.tiers()}
              :if={Map.has_key?(@roster, tier)}
              id={"two-factor-roster-#{tier}"}
            >
              <td class="py-2 font-medium">{tier_label(tier)}</td>
              <td class="py-2 tabular-nums">{@roster[tier].total}</td>
              <td class="py-2 tabular-nums">{@roster[tier].enrolled}</td>
              <td class="py-2 tabular-nums">
                {@roster[tier].in_grace}
                <span
                  :if={@roster[tier].earliest_deadline}
                  class="block text-xs text-base-content/70"
                >
                  {gettext("first deadline %{date}", date: on_date(@roster[tier].earliest_deadline))}
                </span>
              </td>
              <td class="py-2 tabular-nums">{@roster[tier].overdue}</td>
            </tr>
          </tbody>
        </table>

        <p
          :if={@last_change}
          id="two-factor-policy-last-change"
          class="mt-3 text-xs text-base-content/70"
        >
          <%= if @last_change.event do %>
            <%= if previous_label(@last_change.event) do %>
              {gettext("Last changed %{date} by %{who}, from “%{previous}”.",
                date: on_date(@last_change.at),
                who: who(@last_change.event),
                previous: previous_label(@last_change.event)
              )}
            <% else %>
              {gettext("Last changed %{date} by %{who}.",
                date: on_date(@last_change.at),
                who: who(@last_change.event)
              )}
            <% end %>
          <% else %>
            {gettext("Last changed %{date}.", date: on_date(@last_change.at))}
          <% end %>
        </p>
      </section>

      <section id="two-factor-policy-settings" class="mt-10 max-w-2xl">
        <h2 class="text-lg font-medium">{gettext("Requirement")}</h2>

        <.form
          for={@form}
          id="two-factor-policy-form"
          phx-change="preview"
          phx-submit="save"
          class="mt-4 space-y-6"
        >
          <fieldset>
            <legend class="text-sm font-medium">{gettext("Require two-step sign-in for")}</legend>
            <div class="mt-2 grid gap-2 sm:grid-cols-2">
              <label
                :for={choice <- @choices}
                for={"policy_required_for_#{choice}"}
                class={[
                  "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
                  @selected == Atom.to_string(choice) && "border-primary bg-primary/5",
                  @selected != Atom.to_string(choice) &&
                    "border-base-content/15 hover:border-base-content/30"
                ]}
              >
                <input
                  type="radio"
                  id={"policy_required_for_#{choice}"}
                  name={@form[:required_for].name}
                  value={choice}
                  checked={@selected == Atom.to_string(choice)}
                  phx-debounce="300"
                  class="mt-1"
                />
                <span>
                  <span class="block text-sm font-medium">{choice_label(choice)}</span>
                  <span class="block text-xs text-base-content/70">{choice_help(choice)}</span>
                </span>
              </label>
            </div>
          </fieldset>

          <.input
            field={@form[:grace_days]}
            type="select"
            label={gettext("Grace period")}
            options={@grace_options}
            phx-debounce="300"
          />
          <p class="-mt-4 text-xs text-base-content/70">
            {gettext(
              "Counted from when an account was created, joined this site, or became covered, whichever is latest. Promotions don't restart it. After it, the account must set up a second factor before it can do anything else here."
            )}
          </p>

          <p
            :if={@preview}
            id="two-factor-policy-preview"
            role="status"
            class="rounded-lg bg-base-200 p-3 text-sm"
          >
            {ngettext(
              "%{count} person will be asked to set it up;",
              "%{count} people will be asked to set it up;",
              @preview.asked
            )}
            {ngettext(
              "%{count} of them right away.",
              "%{count} of them right away.",
              @preview.now
            )}
          </p>

          <div :if={@needs_code?} id="two-factor-policy-code" class="space-y-1">
            <.input
              name="policy[code]"
              id="policy_code"
              value=""
              type="text"
              inputmode="numeric"
              autocomplete="one-time-code"
              phx-debounce="blur"
              label={gettext("Code from your authenticator app")}
            />
            <p :if={@code_error} id="two-factor-policy-code-error" class="text-sm text-error">
              {@code_error}
            </p>
            <p class="text-xs text-base-content/70">
              {gettext(
                "Changing this setting needs a second factor from the last 15 minutes. Use a code, or sign in again with your passkey."
              )}
            </p>
          </div>

          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
        </.form>
      </section>

      <section id="two-factor-policy-break-glass" class="mt-10 max-w-2xl text-sm">
        <h2 class="text-lg font-medium">{gettext("If nobody can get in")}</h2>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "If no administrator of this site can sign in with a second factor (say the last one lost their only passkey), whoever runs the server can turn the requirement off with the release command KilnCMS.Release.second_factor_requirement_off. It is recorded in this site's security log."
          )}
        </p>
      </section>
    </Layouts.console>
    """
  end
end
