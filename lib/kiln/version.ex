defmodule Kiln.Version do
  @moduledoc """
  What version of Kiln this instance actually is.

  A downstream project pins this repo as a submodule and builds an image from
  it (see `projects/README.md`), so "which Kiln am I running?" has two halves
  that can disagree:

    * the **release version** — `mix.exs`'s `:version`, compiled into the app
      and read back via `Application.spec/2`. Stable, human-readable, and what
      `mix kiln.update` compares against upstream tags;
    * the **build stamp** — the git SHA and build timestamp injected by the
      Dockerfile (`ARG GIT_SHA` / `ARG BUILD_DATE`). Absent in dev and in any
      image built without those build args, hence every field is nilable.

  Nothing here phones home; see `Kiln.Updates` for the upstream check.
  """

  @typedoc "A resolved build identity. Every field but `:version` may be nil."
  @type t :: %__MODULE__{
          version: String.t(),
          git_sha: String.t() | nil,
          built_at: DateTime.t() | nil
        }

  defstruct [:version, :git_sha, :built_at]

  @doc """
  The compiled release version, e.g. `"0.2.0"`.

  Falls back to `"0.0.0"` only if the app spec is somehow unavailable (an
  escript or a bare `Code.require_file`), which keeps callers from having to
  handle nil on the one field that should always exist.
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:kiln_cms, :vsn) do
      nil -> "0.0.0"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  The git SHA baked in at image build time, or nil outside a stamped build.

  Returned in full; callers truncate for display.
  """
  @spec git_sha() :: String.t() | nil
  def git_sha do
    case System.get_env("KILN_GIT_SHA") do
      nil -> nil
      "" -> nil
      sha -> sha
    end
  end

  @doc """
  When the image was built, or nil outside a stamped build.

  The Dockerfile writes an ISO-8601 UTC string; anything unparseable is
  treated as absent rather than raising — a malformed build arg must not take
  the admin page down.
  """
  @spec built_at() :: DateTime.t() | nil
  def built_at do
    with raw when is_binary(raw) and raw != "" <- System.get_env("KILN_BUILD_DATE"),
         {:ok, at, _offset} <- DateTime.from_iso8601(raw) do
      at
    else
      _ -> nil
    end
  end

  @doc "The full build identity as a struct."
  @spec current() :: t()
  def current do
    %__MODULE__{version: version(), git_sha: git_sha(), built_at: built_at()}
  end
end
