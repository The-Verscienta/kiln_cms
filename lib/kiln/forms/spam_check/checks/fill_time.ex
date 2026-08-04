defmodule Kiln.Forms.SpamCheck.Checks.FillTime do
  @moduledoc """
  Flags a submission filled in faster than a human plausibly could —
  scripted spam typically posts within milliseconds of fetching the page; no
  one reads a form and types an answer that fast.

  Reads the `:fill_time_ms` fact rather than computing it: the wall-clock
  delta comes from a signed render-time token
  (`KilnCMS.Forms.rendered_at_token/0` / `KilnCMS.Forms.fill_time_ms/1`), and
  a caller that doesn't compute it (a headless/JSON integration with no
  rendered page to time) gets `:ok` here rather than a false positive from a
  missing signal.
  """
  use Kiln.Forms.SpamCheck

  alias Kiln.Forms.SpamCheck.Context

  @floor_ms 1_500
  @weight 30

  @impl Kiln.Forms.SpamCheck
  def check(context) do
    case Context.fact(context, :fill_time_ms) do
      ms when is_integer(ms) and ms >= 0 and ms < @floor_ms -> flag(:submitted_too_fast, @weight)
      _ -> :ok
    end
  end
end
