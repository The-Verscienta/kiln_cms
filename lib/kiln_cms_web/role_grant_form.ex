defmodule KilnCMSWeb.RoleGrantForm do
  @moduledoc """
  The console side of a temporary role grant (`KilnCMS.Accounts.RoleGrant`):
  the durations offered, turning a submitted form into an expiry, and rendering
  one.

  Shared by `KilnCMSWeb.AccountsLive` (the platform role) and
  `KilnCMSWeb.TeamLive` (a site tier). Both used to carry private copies, and the
  copies already disagreed with their own comment about what an unparseable date
  does — the kind of drift that matters here, because one of the rules is a
  security default (a mangled duration must hand out the *shortest* grant).
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMSWeb.Params

  # Hours as well as days, because the shape this is for — "cover me while I'm on
  # call", "let the contractor publish this afternoon" — is often under a day.
  @durations [
    {"6 hours", 6},
    {"24 hours", 24},
    {"3 days", 72},
    {"7 days", 168},
    {"30 days", 720}
  ]

  @default_hours @durations |> List.first() |> elem(1)

  @doc "The offered grant lengths, as `{label, hours}` select options."
  @spec durations() :: [{String.t(), pos_integer()}]
  def durations, do: @durations

  @doc """
  The expiry a submitted grant form asks for — never `nil`.

  An explicit `"until"` (a `datetime-local` value, read as UTC) wins when it parses.
  Otherwise the `"hours"` preset applies, and an unparseable preset falls back to
  the **shortest** offered duration: a mangled value must not hand out a month of
  admin.

  "Otherwise" includes an `until` that is present but unparseable — a browser that
  renders `datetime-local` as a plain text box accepts any string. It falls back to
  the preset rather than to `nil`: a `nil` expiry reaches the action as "is
  required" on the one field the operator filled in, and on a payload that also
  blanks the role it validates as a no-op *revoke* instead of an error. Whatever
  lands is still validated by `KilnCMS.Accounts.Validations.TemporaryRoleGrant`,
  so a past date is refused with a message there.

  Parameters are read through `KilnCMSWeb.Params`, so a bracketed `until[]=…`
  reads as absent rather than raising.
  """
  @spec expiry(map()) :: DateTime.t()
  def expiry(params) when is_map(params) do
    case parse_until(Params.string(params, "until", "")) do
      %DateTime{} = at -> at
      nil -> DateTime.add(DateTime.utc_now(), preset_hours(params), :hour)
    end
  end

  # `NaiveDateTime.from_iso8601/1` rejects the minute precision `datetime-local`
  # submits (`2026-09-23T14:30`), but some browsers include seconds — so try the
  # value as given, then padded.
  defp parse_until(""), do: nil

  defp parse_until(until) do
    with {:error, _} <- NaiveDateTime.from_iso8601(until),
         {:error, _} <- NaiveDateTime.from_iso8601(until <> ":00") do
      nil
    else
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  defp preset_hours(params) do
    hours = Params.integer(params, "hours", @default_hours, 1..8_760)
    if Enum.any?(@durations, &(elem(&1, 1) == hours)), do: hours, else: @default_hours
  end

  @doc "A grant's expiry as a compact UTC timestamp; `\"\"` for `nil`."
  @spec format(DateTime.t() | nil) :: String.t()
  def format(nil), do: ""
  def format(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
