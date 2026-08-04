defmodule Kiln.Forms.SpamCheck do
  @moduledoc """
  The contract for a **form-submission spam check** (#477) — the same
  discovered-at-runtime shape `Kiln.Advisory` uses for the editor's advice
  panel, adapted for a weighted score instead of a severity-tiered finding.

  A check is a pure function over a `Kiln.Forms.SpamCheck.Context`: no
  database, no network. It runs once per submission (not per keystroke, so
  the cost story is looser than `Kiln.Advisory`'s — but I/O still belongs to
  the caller building the context, via `facts`, exactly as `Kiln.Advisory`
  does it).

      defmodule MyPlugin.SpamChecks.TooManyEmoji do
        use Kiln.Forms.SpamCheck

        @impl Kiln.Forms.SpamCheck
        def check(context) do
          if emoji_count(Context.text(context)) > 10, do: flag(:too_many_emoji, 20), else: :ok
        end
      end

  and lists it from the plugin entry module:

      @impl Kiln.Plugin
      def spam_checks, do: [MyPlugin.SpamChecks.TooManyEmoji]

  ## Two outcomes, and a weight instead of a severity

  `check/1` returns `:ok` (nothing to flag — either genuinely clean, or the
  fact this check needs is absent) or `{:flag, reason, weight}`. There is no
  `Kiln.Advisory`-style `:n_a`: a spam check either has an opinion or it
  doesn't, and "no opinion" and "clean" both mean "contributes nothing to the
  score" here, unlike an advisory panel that wants to report on the checks
  that genuinely don't apply.

  `Kiln.Forms.SpamCheck.Registry.score/1` sums every flagged weight;
  `KilnCMS.CMS.Changes.ScoreFormSubmission` compares the sum against
  `threshold/0` to decide `:spam`.
  """

  alias Kiln.Forms.SpamCheck.Context

  @type reason :: atom()
  @type weight :: pos_integer()
  @type outcome :: :ok | {:flag, reason(), weight()}

  @doc """
  Judge `context`. Pure — no IO, no database, no network.

  The check module itself is its identifier, so there is no `id/0` to
  implement and nothing to keep in sync.
  """
  @callback check(Context.t()) :: outcome() | [outcome()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Forms.SpamCheck

      import Kiln.Forms.SpamCheck, only: [flag: 2]
    end
  end

  @doc "Build a flagged outcome: a reason code and how much it weighs."
  @spec flag(reason(), weight()) :: outcome()
  def flag(reason, weight) when is_atom(reason) and is_integer(weight) and weight > 0,
    do: {:flag, reason, weight}

  @doc """
  The score past which a submission is stored `:spam` (config-gated, default
  `50`).

      config :kiln_cms, Kiln.Forms.SpamCheck, threshold: 50
  """
  @spec threshold() :: pos_integer()
  def threshold,
    do: :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:threshold, 50)
end
