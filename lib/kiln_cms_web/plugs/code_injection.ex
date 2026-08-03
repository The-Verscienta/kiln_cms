defmodule KilnCMSWeb.Plugs.CodeInjection do
  @moduledoc """
  Resolves a site's custom head/footer HTML and widens its CSP to match (#490).

  **Runs in the `:delivery` pipeline and nowhere else.** That placement is the
  security model, not a routing convenience: the root layout is shared between
  the public site and the editor console, so "only render this on delivery" has
  to be enforced somewhere that the console cannot reach. A pipeline the console
  does not pipe through enforces it structurally — an org admin's snippet can
  never execute in a Kiln operator's authenticated console session, and nobody
  has to remember a conditional in a template to keep that true.

  The plug does two things together, and they must stay together: it assigns the
  HTML the layout emits, and it rewrites the `content-security-policy` header
  that decides whether that HTML does anything. Assigning one without the other
  produces a site whose settings form shows a saved snippet that silently never
  runs.

  ## Rewriting rather than appending

  `put_browser_csp` has already set the header by the time this runs, so this
  edits the existing directives — `script-src`, `connect-src`, `img-src` — in
  place. Emitting a second `content-security-policy` header would be worse than
  useless: browsers intersect multiple policies, so the extra sources would be
  ignored and the snippet would stay blocked, which is the failure that looks
  exactly like the feature not being wired up.

  A site with no injection is left byte-identical. Nothing about the stock CSP
  changes for the sites that do not use this.
  """
  @behaviour Plug

  alias KilnCMS.CodeInjection

  @directives [{:script_src, "script-src"}, {:connect_src, "connect-src"}, {:img_src, "img-src"}]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    injection = CodeInjection.for_org(conn.assigns[:current_org])

    conn
    |> Plug.Conn.assign(:code_injection, injection)
    |> widen_csp(injection)
  end

  defp widen_csp(conn, injection) do
    sources = CodeInjection.csp_sources(injection)

    if Enum.all?(@directives, fn {key, _name} -> sources[key] == [] end) do
      conn
    else
      Plug.Conn.update_resp_header(
        conn,
        "content-security-policy",
        "",
        &apply_sources(&1, sources)
      )
    end
  end

  defp apply_sources(policy, sources) do
    Enum.reduce(@directives, policy, fn {key, name}, acc ->
      widen(acc, name, sources[key])
    end)
  end

  defp widen(policy, _name, []), do: policy

  defp widen(policy, name, values) do
    addition = Enum.join(values, " ")

    policy
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.map_reduce(false, fn directive, found? ->
      if directive == name or String.starts_with?(directive, name <> " ") do
        {directive <> " " <> addition, true}
      else
        {directive, found?}
      end
    end)
    |> case do
      # A directive the policy does not name falls back to `default-src`, so
      # adding sources means adding the directive rather than silently doing
      # nothing. `connect-src` and `img-src` are both in the base policy today;
      # this is what keeps that from being a load-bearing coincidence.
      {directives, false} -> Enum.join(directives ++ ["#{name} 'self' #{addition}"], "; ")
      {directives, true} -> Enum.join(directives, "; ")
    end
  end
end
