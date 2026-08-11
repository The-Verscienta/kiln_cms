defmodule KilnCMS.Environment do
  @moduledoc """
  Which deployment the operator is looking at (#469).

  A scrubbed staging clone (`KilnCMS.Staging`, `docs/staging-environments.md`) is
  a byte-for-byte copy of production's content and branding, so its console is
  *visually identical* to the real one. That is what invites "I edited the wrong
  environment" — the incident this exists to prevent.

  `KILN_ENV_LABEL` turns on a strip across the top of every console page.
  **Absent means no strip**, so production stays clean by default and nothing has
  to be configured for the environment that must not be labelled. Staging and
  development set it; production is the one you recognise by the *absence* of a
  warning.

  ## The tone is a kit name, never a colour

  `KILN_ENV_COLOR` names one of the design kit's tones — #{Enum.join(~w(warning error info success),
  ", ")}. Not a hex: the kit pairs every tone with an `-ink` token chosen to clear
  WCAG contrast against that tone's tint, and a hand-supplied colour would take
  the tint while keeping ink picked for a different one (the standing rule in
  `assets/css/app.css` and `docs/design-language.md`). An unrecognized name falls
  back to `warning` with a log line — fail to the *default*, not to silence, the
  same rule `KilnCMS.Config.Env` applies to the boolean variables.

  There is deliberately no `neutral`: the kit's neutral fill is `bg-base-200`,
  which sits about 1.06:1 against the page it would be drawn on. A strip nobody
  can see is worse than no strip, because it looks handled.
  """
  require Logger

  @tones ~w(warning error info success)
  @default_tone "warning"

  @doc """
  The environment's display label, or `nil` when this deployment isn't labelled.

  `nil` is the whole production story: no variable, no strip, nothing to
  configure on the deployment where a mislabel would be worst.
  """
  @spec label() :: String.t() | nil
  def label do
    case config()[:label] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  @doc """
  The design-kit tone name to render the strip in.

  Only meaningful when `label/0` is set — and only *called* then, because the
  fallback logs: this runs once per console render, so warning about a tone on a
  deployment that shows no strip would repeat forever about a value nothing uses.
  """
  @spec tone() :: String.t()
  def tone do
    case config()[:tone] do
      nil ->
        @default_tone

      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        if normalized in @tones, do: normalized, else: fallback(value)

      other ->
        # Configured from Elixir rather than an env var, e.g. `tone: :error`.
        # Silently defaulting here would leave the strip in the wrong colour
        # with nothing anywhere saying why.
        fallback(other)
    end
  end

  @doc "The tone names `KILN_ENV_COLOR` accepts."
  @spec tones() :: [String.t()]
  def tones, do: @tones

  defp fallback(value) do
    Logger.warning(
      "KILN_ENV_COLOR=#{inspect(value)} is not one of #{Enum.join(@tones, ", ")} — " <>
        "using #{@default_tone}."
    )

    @default_tone
  end

  defp config, do: Application.get_env(:kiln_cms, :environment, [])
end
