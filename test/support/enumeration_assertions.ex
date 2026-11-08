defmodule KilnCMS.EnumerationAssertions do
  @moduledoc """
  Asserts that a known and an unknown address are **indistinguishable** to the
  caller of an identity surface (#2255).

  "Indistinguishable" is an exact comparison of everything a caller can see,
  not a substring check: a `=~ "Incorrect"` on both sides passes just as happily
  when one response also says "no such account" three lines further down. So
  `observe/2` reduces a response to one plain term and `assert_indistinguishable/3`
  compares the two terms whole.

    * a `Plug.Conn` becomes its status, content type, `location`, the
      credential-relevant headers, the complete flash and the complete body;
    * HTML from a `Phoenix.LiveViewTest` render becomes the complete markup;
    * anything else (a `:ok`, an `{:error, _}` from an Ash action) is compared
      as it is, after the same address scrub.

  ## What is scrubbed, and only that

  The addresses themselves (`:emails`, plain and HTML-escaped), because a form
  that echoes what was typed is not a disclosure — the caller typed it — and
  the per-render noise that differs between *any* two renders of the same page:
  CSRF tokens, the per-response CSP script nonce, and LiveView's
  session/static/id attributes. Everything else is compared byte for byte.

  ## What this cannot see

  Time. A passing assertion says the two responses carry the same information;
  it says nothing about how long each took to produce. Timing is covered, where
  it is covered at all, by asserting the same *work* ran (`count_calls/2`),
  never a wall clock.
  """
  import ExUnit.Assertions

  @redirect_headers ["location", "www-authenticate", "retry-after"]

  @doc """
  Reduces `response` to the term the caller can observe, with `emails` and the
  per-render noise scrubbed out.
  """
  @spec observe(Plug.Conn.t() | String.t() | term(), [String.t()]) :: term()
  def observe(%Plug.Conn{} = conn, emails) do
    %{
      status: conn.status,
      content_type: Plug.Conn.get_resp_header(conn, "content-type"),
      headers:
        for(
          name <- @redirect_headers,
          value <- Plug.Conn.get_resp_header(conn, name),
          do: {name, scrub(value, emails)}
        ),
      flash: conn |> flash() |> scrub(emails),
      body: scrub(conn.resp_body, emails)
    }
  end

  def observe(html, emails) when is_binary(html), do: scrub(html, emails)
  def observe(other, emails), do: scrub(other, emails)

  # The flash a redirecting response leaves behind. It travels in the session
  # (`before_send` has already moved it there), so that is the one place that
  # holds the whole of it; `conn.private` only has what was `put_flash`ed on
  # the way out and is empty again once the session took it.
  defp flash(conn) do
    case conn.private do
      %{plug_session: %{"phoenix_flash" => flash}} -> flash
      %{phoenix_flash: flash} -> flash
      _ -> %{}
    end
  end

  @doc """
  Runs `known` and `unknown` (zero-arity functions returning a response) and
  asserts the observable results are equal.

  `emails` lists the addresses to scrub from both sides. Returns the shared
  observation so a caller can additionally pin what it is (a 401, a redirect).
  """
  @spec assert_indistinguishable((-> term()), (-> term()), [String.t()]) :: term()
  def assert_indistinguishable(known, unknown, emails) when is_list(emails) do
    seen_known = observe(known.(), emails)
    seen_unknown = observe(unknown.(), emails)

    assert seen_known == seen_unknown,
           """
           a known and an unknown address are distinguishable.

           known:   #{inspect(seen_known, limit: :infinity, printable_limit: :infinity)}
           unknown: #{inspect(seen_unknown, limit: :infinity, printable_limit: :infinity)}
           """

    seen_known
  end

  @doc """
  Counts calls to each `{module, function, arity}` while `fun` runs in this
  process (and any process it spawns), returning `{result, %{mfa => count}}`.

  The tool for "the unknown path does the same *work*" — e.g. one bcrypt check
  on either side — in place of a wall-clock assertion that would flake.

  Counts go to a collector process of their own: a process traced with itself
  as the tracer is delivered nothing.
  """
  @spec count_calls((-> term()), [{module(), atom(), arity()}]) ::
          {term(), %{{module(), atom(), arity()} => non_neg_integer()}}
  def count_calls(fun, mfas) do
    subject = self()
    collector = spawn_link(fn -> collect(Map.new(mfas, &{&1, 0})) end)

    Enum.each(mfas, fn {m, f, a} ->
      Code.ensure_loaded!(m)
      1 = :erlang.trace_pattern({m, f, a}, true, [:local])
    end)

    :erlang.trace(subject, true, [:call, :set_on_spawn, {:tracer, collector}])

    try do
      result = fun.()
      # Trace messages are asynchronous; wait until every one has been handed
      # to the collector before asking it for the tally.
      ref = :erlang.trace_delivered(subject)

      receive do
        {:trace_delivered, ^subject, ^ref} -> :ok
      end

      send(collector, {:tally, self()})

      receive do
        {:tally, counts} -> {result, counts}
      end
    after
      # The patterns are left set on purpose: they are VM-wide, so clearing
      # them would blind a concurrent async test counting the same function,
      # and they emit nothing for a process that is not traced.
      :erlang.trace(subject, false, [:call, :set_on_spawn])
    end
  end

  defp collect(counts) do
    receive do
      {:trace, _pid, :call, {m, f, args}} ->
        # Patterns are VM-wide and left set (see `count_calls/2`), so a call to
        # a function another test asked about arrives here too; only the
        # requested ones are tallied.
        key = {m, f, length(args)}
        collect(if is_map_key(counts, key), do: Map.update!(counts, key, &(&1 + 1)), else: counts)

      {:tally, from} ->
        send(from, {:tally, counts})
    end
  end

  # -- scrubbing ------------------------------------------------------------

  defp scrub(value, emails) when is_binary(value) do
    emails
    |> Enum.reduce(value, fn email, acc ->
      acc
      |> String.replace(email, "<EMAIL>")
      |> String.replace(html_escape(email), "<EMAIL>")
      |> String.replace(URI.encode_www_form(email), "<EMAIL>")
    end)
    |> String.replace(~r/(name="_csrf_token"[^>]*value=")[^"]*/, "\\1<CSRF>")
    |> String.replace(~r/(value=")[A-Za-z0-9_\-]{20,}(" name="_csrf_token")/, "\\1<CSRF>\\2")
    |> String.replace(~r/(content=")[A-Za-z0-9_\-]{20,}(" name="csrf-token")/, "\\1<CSRF>\\2")
    |> String.replace(~r/(csrf-token"[^>]*content=")[^"]*/, "\\1<CSRF>")
    |> String.replace(~r/data-phx-(session|static|main|root-id|parent-id)="[^"]*"/, "")
    |> String.replace(~r/ id="phx-[\w\-]+"/, "")
    |> String.replace(~r/ data-phx-[a-z\-]+="[^"]*"/, "")
    |> String.replace(~r/ nonce="[^"]*"/, ~s( nonce="<NONCE>"))
  end

  defp scrub(map, emails) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, scrub(v, emails)} end)

  defp scrub(list, emails) when is_list(list), do: Enum.map(list, &scrub(&1, emails))
  defp scrub({a, b}, emails), do: {scrub(a, emails), scrub(b, emails)}
  defp scrub(other, _emails), do: other

  defp html_escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
