defmodule KilnCMS.Security.AlertText do
  @moduledoc """
  The one-line wording of a security alert (#2245, #2642): the kind and
  change labels, and the headline built from them. The bell and inbox excerpt
  (`KilnCMSWeb.NotificationText.excerpt/1`) and the email
  (`KilnCMS.Security.AlertMail`) both say it through here, so they cannot
  drift apart.

  Every label goes through `KilnCMSWeb.Gettext`, so the caller's locale
  decides the language. The inbox renders in the reader's locale; the email
  pins English (see `KilnCMS.Security.AlertMail`).

  ## Details, not the payload

  `details/1` reduces an alert's payload (the map its webhooks carry,
  `KilnCMS.Security.Changes.DeliverAlert`) to the few values a headline is
  made of: `phase`, `kind`, `channel`, `change`, `kinds`, `count`, the
  display `ip` and the `event_type`. That map is stored on the bell row as
  `Notification.details`, with string keys, so the inbox can say the line
  again in another language. It holds nothing the English excerpt did not
  already say: the address is the one the site's settings allow
  (`KilnCMS.Security.Alerts.display_ip/2`), never the user agent, an email
  address or a URL.

  A kind or change this release does not know (a newer node wrote the row
  during a rolling deploy) falls back to a neutral label rather than raising.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @typedoc "What `details/1` returns and `headline/1` reads: string keys only."
  @type details :: %{optional(String.t()) => term()}

  @doc """
  The values a headline is made of, from an alert's payload. String keys,
  because the map is stored as JSON and read back that way.

  The payload may have atom keys (as `KilnCMS.Security.Changes.DeliverAlert`
  builds it) or string keys (as the webhook ledger hands it back to
  `KilnCMS.Webhooks.SlackFormat`).
  """
  @spec details(map()) :: details()
  def details(data) when is_map(data) do
    event = field(data, :event) || %{}

    %{
      "phase" => field(data, :phase),
      "kind" => field(data, :kind),
      "channel" => field(data, :channel),
      "change" => field(data, :change),
      "kinds" => List.wrap(field(data, :kinds)),
      "count" => field(data, :count),
      "ip" => field(event, :ip),
      "event_type" => field(event, :type)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  @doc """
  One line saying what happened, in the current locale, from `details/1`'s
  map.
  """
  @spec headline(details()) :: String.t()
  def headline(%{"phase" => "notice"} = details), do: change_label(details["change"])

  def headline(%{"phase" => "summary", "count" => count} = details),
    do:
      gettext("%{label}: %{count} in this alert window",
        label: kind_label(details["kind"]),
        count: count
      )

  def headline(%{"ip" => ip} = details) when is_binary(ip),
    do: gettext("%{label} (from %{ip})", label: kind_label(details["kind"]), ip: ip)

  def headline(details) when is_map(details), do: kind_label(details["kind"])

  @doc "The label of an alert kind, in the current locale."
  @spec kind_label(String.t() | atom() | nil) :: String.t()
  def kind_label(kind) when is_atom(kind) and not is_nil(kind), do: kind_label(to_string(kind))
  def kind_label("new_admin"), do: gettext("A new administrator")
  def kind_label("role_elevation"), do: gettext("A role was raised")
  def kind_label("failed_sign_ins"), do: gettext("Failed sign-ins reached the alert threshold")
  def kind_label("lockout"), do: gettext("An account was locked out")
  def kind_label("two_factor_disabled"), do: gettext("Two-step verification was turned off")
  def kind_label("sso_config_changed"), do: gettext("Single sign-on settings changed")
  def kind_label("platform_role_changed"), do: gettext("A platform administrator lost the role")
  def kind_label("new_api_key"), do: gettext("An API key was created")
  def kind_label("api_key_abuse"), do: gettext("A rotated API key was used again")
  def kind_label(_unknown), do: gettext("Security alert")

  @doc "The label of an `alerts_silenced` notice's change, in the current locale."
  @spec change_label(String.t() | nil) :: String.t()
  def change_label("kind_disabled"), do: gettext("Some security alerts were turned off")

  def change_label("admin_notifications_off"),
    do: gettext("Security alert notifications and emails were turned off")

  def change_label("webhook_changed"),
    do: gettext("A webhook that receives security alerts was changed")

  def change_label("webhook_removed"),
    do: gettext("A webhook that receives security alerts was deleted")

  def change_label("webhook_secret_rotated"),
    do: gettext("A webhook that receives security alerts got a new signing secret")

  def change_label("webhook_auto_disabled"),
    do:
      gettext("A webhook that receives security alerts was switched off after failed deliveries")

  def change_label("admin_removed"), do: gettext("An administrator was removed")
  def change_label("admin_demoted"), do: gettext("An administrator was demoted")

  def change_label("admin_grant_revoked"),
    do: gettext("A temporary administrator role was ended early")

  def change_label("mail_relay_changed"), do: gettext("The site's mail relay was changed")
  def change_label(_unknown), do: gettext("Security alerts were made quieter")
end
