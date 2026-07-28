defmodule Kiln.Advisory.Checks.ImageAlt do
  @moduledoc """
  Images with no alt text.

  An `:error` rather than a warning: alt text is the one advisory here with
  legal weight, and an image without it is simply unreadable to a screen-reader
  user. The finding carries the offending blocks' positions so the editor can
  offer jump links.

  Neutral namespace on purpose — this is #495's check as much as #476's, and
  `KilnCMS.Media` (#403) enforces alt at the library level. Detecting is
  deliberately all it does: Kiln does not generate alt text, because a
  hallucinated description passes an automated audit while lying to the person
  relying on it.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  @impl Kiln.Advisory
  def check(%Context{body: %{image_count: 0}}), do: :n_a
  def check(%Context{body: %{images_missing_alt: []}}), do: :ok

  def check(%Context{body: %{images_missing_alt: indexes}}) do
    finding(:error, :images_missing_alt, :images, %{
      count: length(indexes),
      indexes: indexes
    })
  end
end
