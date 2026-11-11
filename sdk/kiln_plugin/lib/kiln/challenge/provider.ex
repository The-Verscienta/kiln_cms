defmodule Kiln.Challenge.Provider do
  @moduledoc """
  The contract for a **human-verification provider** (kiln_cms#2249): a
  widget the browser draws, and a check that later says whether the token
  that widget produced is genuine.

  KilnCMS ships two: Cloudflare Turnstile (`turnstile`, recommended) and
  Google reCAPTCHA v2 (`recaptcha`). A plugin contributes another from its
  entry module, and the operator picks one by its `c:id/0`:

      @impl Kiln.Plugin
      def challenge_providers, do: [MyPlugin.Captcha]

      # the operator's environment
      CHALLENGE_PROVIDER=my_captcha

  Installing a provider changes nothing until the operator names it. A
  provider id nobody installed, or a provider that fails `conformance/1`,
  leaves human verification **off**, with a boot warning and a log line,
  exactly as if no provider were named. A built-in id always wins over a
  plugin's.

      defmodule MyPlugin.Captcha do
        use Kiln.Challenge.Provider

        @impl Kiln.Challenge.Provider
        def id, do: "my_captcha"

        @impl Kiln.Challenge.Provider
        def widget,
          do: %{
            script_url: "https://captcha.example.com/v1/api.js?render=explicit",
            global: "myCaptcha"
          }

        @impl Kiln.Challenge.Provider
        def csp_sources,
          do: %{
            script_src: ["https://captcha.example.com/v1/"],
            frame_src: ["https://captcha.example.com"],
            connect_src: []
          }

        @impl Kiln.Challenge.Provider
        def verify(token, opts) do
          post = Keyword.fetch!(opts, :post)

          case post.("https://captcha.example.com/v1/verify", [
                 {"secret", opts[:secret]},
                 {"response", token}
               ]) do
            {:ok, %{status: 200, body: body}} -> judge(body)
            {:ok, %{status: status}} when status >= 500 or status == 429 ->
              {:error, {:unavailable, :http_status}}

            {:ok, _refused} -> {:error, :invalid}
            {:error, :timeout} -> {:error, {:unavailable, :timeout}}
            {:error, _transport} -> {:error, {:unavailable, :transport}}
          end
        end

        # `body` is the provider's raw answer; decode it and report what it
        # claims. The core checks the hostname and action itself.
        defp judge(body) do
          case Jason.decode(body) do
            {:ok, %{"success" => true} = answer} ->
              {:ok, %{hostname: answer["hostname"], action: answer["action"]}}

            {:ok, %{"success" => false}} ->
              {:error, :invalid}

            _unreadable ->
              {:error, {:unavailable, :malformed_response}}
          end
        end
      end

  ## The browser half

  `c:widget/0` describes the script and how to call it. KilnCMS's own hook
  loads `script_url` once per page (never through an inline script) and
  calls the global it defines. The keys:

    * `script_url` — `https://` only, no credentials, and covered by one of
      the `script_src` entries in `c:csp_sources/0`.
    * `global` — the JavaScript global the script defines, a plain
      identifier.
    * `api` — which browser API the global offers. `:explicit_render` (the
      default, and today the only value) means `render(element, options)`
      returning a widget id, plus `reset(id)`; `remove(id)` is called when
      present. `options` carries `sitekey`, `callback`, `expired-callback`
      and `error-callback`. It is the discriminator a later widget kind will
      be added under, so a provider written now keeps working.
    * `render_options` — extra options passed to `render/2`, a JSON-safe map
      with string keys (default `%{}`). It may not set `sitekey` or any of
      the callbacks.
    * `action_option` — the `render/2` option that carries the action the
      widget is drawn for (`"sign_in"`, `"register"`, `"form"`), or `nil`
      when the widget has none (default `nil`).
    * `onload_param` — when the script must be told when it is ready, the
      query parameter that names a global callback (reCAPTCHA's `onload`);
      the hook then waits for that callback rather than the script's own
      `load` event. `nil` (the default) waits for `load`.
    * `response_field` — the form field the provider's own markup posts the
      token under, if it adds one (`"g-recaptcha-response"`). KilnCMS reads
      it as a fallback and keeps it out of logs and error reports.
    * `interactive` — `true` when people normally have to click or solve
      something (a checkbox). A public form then asks them to complete the
      check before it sends, instead of waiting for an invisible check to
      finish. Default `false`.

  `c:csp_sources/0` lists what the page's Content-Security-Policy must add
  while the widget can be drawn — and only then. Each entry is
  `https://host[:port][/path]`: no wildcards, no keywords, no quotes, no
  `;` or `,`. A path ending in `/` allows everything under it.

  ## The server half

  `c:verify/2` gets the token (already checked to be a short printable
  string) and these options:

    * `:secret` — the operator's secret key.
    * `:action` — `"sign_in"`, `"register"` or `"form"`.
    * `:remote_ip` — the client address, present only when the operator
      turned `send_remote_ip` on; send nothing otherwise.
    * `:post` — `fn url, fields -> result end`, the core's transport: a
      form-encoded `POST` that answers `{:ok, %{status: integer, body:
      binary}}` or `{:error, class}` (`:timeout`, `:transport`, `:blocked`,
      `:malformed_response`). It is the only way out: the core owns the
      timeouts, the byte cap and the no-redirect rule, and runs the whole
      call under a deadline in its own task.

  It answers:

    * `{:ok, claims}` — the provider says the token is genuine, and
      `claims` is what it reported about where it was solved:
      `%{hostname: "…" | nil, action: "…" | nil}`. The keys may also be the
      strings `"hostname"` and `"action"`.
    * `{:error, refusal}` — the token is not good: `:invalid`, `:expired`,
      `:hostname_mismatch` or `:action_mismatch`.
    * `{:error, {:unavailable, reason}}` — it could not tell (see
      `t:unavailable/0`).

  The core, not the provider, enforces the claims. **A pass without a
  `hostname` is refused** while the deployment's hostname check is on, which
  is the default: report the hostname the provider's answer names. A
  `hostname` that is not a host this deployment serves is refused too, and so
  is an `action` that is present and differs from the one the widget was
  drawn for. A provider whose answers always carry the action should refuse
  an answer without one itself.

  Only "unavailable" may ever let an attempt through without a pass, and only
  within the core's bounds, so a provider must never report a refusal it got
  as unavailable, nor an answer it did not get as a pass. Anything but
  `{:ok, _}` and `{:error, _}` is treated as the provider crashing. Any
  `{:error, reason}` whose reason is not one of the refusals above — `:missing`
  and `:malformed` included, which belong to the core's own check before a
  provider is asked, and a string or tuple too — is read as `:invalid`, so a
  provider can never turn a bad token into "no token" or "unavailable".

  ## Called once, not per request

  `c:id/0`, `c:label/0`, `c:widget/0` and `c:csp_sources/0` are read once per
  node and memoised: they must return constants, and must not block, read the
  network or depend on the request. Only `c:verify/2` runs per attempt.

  ## Conformance

  `conformance/1` checks a module against all of the above without calling
  `c:verify/2`, and names every problem. The core runs it once before using a
  provider, and `mix kiln.plugins.doctor` runs it for every installed one; a
  plugin's own test can too:

      assert Kiln.Challenge.Provider.conformance(MyPlugin.Captcha) == :ok

  Within 1.x the rules only ever loosen: a provider that conforms today keeps
  conforming. Wildcard hosts (`https://*.example.com`) are refused for now and
  may be allowed later.
  """

  @typedoc "Origins the widget needs in the page's Content-Security-Policy."
  @type csp_sources :: %{
          script_src: [String.t()],
          frame_src: [String.t()],
          connect_src: [String.t()]
        }

  @typedoc "A value `render_options` may hold: anything that encodes as JSON."
  @type json ::
          nil | boolean() | number() | String.t() | [json()] | %{optional(String.t()) => json()}

  @typedoc "What `c:widget/0` returns. Only `script_url` and `global` are required."
  @type widget :: %{
          required(:script_url) => String.t(),
          required(:global) => String.t(),
          optional(:api) => :explicit_render,
          optional(:render_options) => %{optional(String.t()) => json()},
          optional(:action_option) => String.t() | nil,
          optional(:onload_param) => String.t() | nil,
          optional(:response_field) => String.t() | nil,
          optional(:interactive) => boolean()
        }

  @typedoc "A token the provider looked at and turned down."
  @type refusal :: :invalid | :expired | :hostname_mismatch | :action_mismatch

  @typedoc """
  Why the provider could not answer: the deadline passed (`:timeout`), the
  connection failed (`:transport`), it answered `5xx` or `429`
  (`:http_status`), the answer was not the expected shape
  (`:malformed_response`), the operator's secret was refused or unreadable
  (`:not_configured`), or the provider crashed (`:crashed`).
  """
  @type unavailable ::
          :timeout
          | :transport
          | :http_status
          | :malformed_response
          | :not_configured
          | :crashed

  @typedoc """
  Where the provider says the token was solved: `:hostname` and `:action`
  (or the string keys `"hostname"` and `"action"`), each a string or `nil`.
  """
  @type claims :: %{optional(:hostname | :action | String.t()) => String.t() | nil}

  @type result ::
          {:ok, claims()}
          | {:error, refusal()}
          | {:error, {:unavailable, unavailable()}}

  @typedoc "A provider as `describe/1` resolves it: every default filled in."
  @type description :: %{
          id: String.t(),
          label: String.t(),
          widget: %{
            script_url: String.t(),
            global: String.t(),
            api: :explicit_render,
            render_options: %{optional(String.t()) => json()},
            action_option: String.t() | nil,
            onload_param: String.t() | nil,
            response_field: String.t() | nil,
            interactive: boolean()
          },
          csp_sources: csp_sources()
        }

  @doc """
  The id an operator names the provider by (`CHALLENGE_PROVIDER`): a
  lowercase letter, then up to 31 lowercase letters, digits or `_`.
  """
  @callback id() :: String.t()

  @doc "A human name for logs and the operator. `use` defaults it from the module name."
  @callback label() :: String.t()

  @doc "The browser half: the script, its global and how to call it (see the moduledoc)."
  @callback widget() :: widget()

  @doc "Origins the widget needs in the page's Content-Security-Policy."
  @callback csp_sources() :: csp_sources()

  @doc "Whether `token` is a genuine, unspent answer (see the moduledoc)."
  @callback verify(token :: String.t(), opts :: keyword()) :: result()

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Challenge.Provider

      @impl Kiln.Challenge.Provider
      def label do
        __MODULE__ |> Module.split() |> List.last()
      end

      defoverridable label: 0
    end
  end

  @id ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @js_identifier ~r/\A[A-Za-z_$][A-Za-z0-9_$]{0,63}\z/
  @option_name ~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/
  @field_name ~r/\A[A-Za-z0-9_\-\[\]]{1,64}\z/
  @csp_source ~r/\Ahttps:\/\/(?<host>[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*)(?::(?<port>[0-9]{1,5}))?(?<path>\/[A-Za-z0-9._~\/-]*)?\z/i
  @reserved_options ~w(sitekey callback expired-callback error-callback)
  @widget_keys [
    :script_url,
    :global,
    :api,
    :render_options,
    :action_option,
    :onload_param,
    :response_field,
    :interactive
  ]
  @csp_keys [:script_src, :frame_src, :connect_src]

  @doc """
  `:ok` when `module` is a usable provider, or `{:error, problems}` naming
  every way it is not. Calls every callback but `c:verify/2`; one that raises
  is a problem, never a crash.
  """
  @spec conformance(module()) :: :ok | {:error, [String.t()]}
  def conformance(module) do
    case describe(module) do
      {:ok, _description} -> :ok
      {:error, problems} -> {:error, problems}
    end
  end

  @doc """
  `module` resolved for use: `{:ok, description}` with every default of
  `c:widget/0` filled in, or `{:error, problems}` as `conformance/1` reports
  them.
  """
  @spec describe(module()) :: {:ok, description()} | {:error, [String.t()]}
  def describe(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and implements?(module) do
      {id, id_problems} = check_id(call(module, :id))
      {label, label_problems} = check_label(call(module, :label))
      {csp, csp_problems} = check_csp(call(module, :csp_sources))
      {widget, widget_problems} = check_widget(call(module, :widget), csp)

      case id_problems ++ label_problems ++ widget_problems ++ csp_problems do
        [] -> {:ok, %{id: id, label: label, widget: widget, csp_sources: csp}}
        problems -> {:error, problems}
      end
    else
      {:error, ["#{inspect(module)} does not implement Kiln.Challenge.Provider"]}
    end
  end

  def describe(other), do: {:error, ["#{inspect(other)} is not a module"]}

  defp implements?(module) do
    Enum.all?(
      [id: 0, label: 0, widget: 0, csp_sources: 0, verify: 2],
      fn {name, arity} -> function_exported?(module, name, arity) end
    )
  end

  defp call(module, name) do
    {:ok, apply(module, name, [])}
  rescue
    error -> {:raised, name, Exception.message(error)}
  catch
    kind, reason -> {:raised, name, "#{kind}: #{inspect(reason)}"}
  end

  defp check_id({:ok, id}) when is_binary(id) do
    if Regex.match?(@id, id),
      do: {id, []},
      else:
        {nil,
         ["id/0 must be a lowercase letter then up to 31 of a-z, 0-9 or _, got #{inspect(id)}"]}
  end

  defp check_id(other), do: {nil, [problem("id/0", other, "a string")]}

  defp check_label({:ok, label}) when is_binary(label) and label != "", do: {label, []}
  defp check_label(other), do: {nil, [problem("label/0", other, "a non-empty string")]}

  defp check_csp({:ok, %{} = sources}) do
    unknown = Map.keys(sources) -- @csp_keys

    {normalized, problems} =
      Enum.reduce(@csp_keys, {%{}, []}, fn key, {acc, problems} ->
        case Map.get(sources, key, []) do
          list when is_list(list) ->
            bad = Enum.reject(list, &csp_source?/1)

            {Map.put(acc, key, list),
             problems ++
               Enum.map(
                 bad,
                 &"csp_sources/0 #{key} entry #{inspect(&1)} must be https://host[:port][/path]"
               )}

          other ->
            {Map.put(acc, key, []),
             problems ++ ["csp_sources/0 #{key} must be a list, got #{inspect(other)}"]}
        end
      end)

    unknown_problems =
      for key <- unknown, do: "csp_sources/0 has an unknown key #{inspect(key)}"

    {normalized, problems ++ unknown_problems}
  end

  defp check_csp(other) do
    {%{script_src: [], frame_src: [], connect_src: []},
     [problem("csp_sources/0", other, "a map of script_src, frame_src and connect_src")]}
  end

  defp csp_source?(source) when is_binary(source) do
    case Regex.named_captures(@csp_source, source) do
      %{"port" => port} -> port == "" or String.to_integer(port) in 1..65_535
      nil -> false
    end
  end

  defp csp_source?(_source), do: false

  defp check_widget({:ok, %{} = widget}, csp) do
    unknown = Map.keys(widget) -- @widget_keys

    normalized = %{
      script_url: Map.get(widget, :script_url),
      global: Map.get(widget, :global),
      api: Map.get(widget, :api, :explicit_render),
      render_options: Map.get(widget, :render_options, %{}),
      action_option: Map.get(widget, :action_option),
      onload_param: Map.get(widget, :onload_param),
      response_field: Map.get(widget, :response_field),
      interactive: Map.get(widget, :interactive, false)
    }

    problems =
      Enum.map(unknown, &"widget/0 has an unknown key #{inspect(&1)}") ++
        script_url_problems(normalized.script_url, csp.script_src) ++
        pattern_problems(:global, normalized.global, @js_identifier, false) ++
        api_problems(normalized.api) ++
        render_options_problems(normalized.render_options) ++
        pattern_problems(:action_option, normalized.action_option, @option_name, true) ++
        pattern_problems(:onload_param, normalized.onload_param, @js_identifier, true) ++
        pattern_problems(:response_field, normalized.response_field, @field_name, true) ++
        interactive_problems(normalized.interactive)

    {normalized, problems}
  end

  defp check_widget(other, _csp), do: {nil, [problem("widget/0", other, "a map")]}

  defp script_url_problems(url, script_src) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      String.match?(url, ~r/[\s"'<>\\]/) ->
        ["widget/0 script_url must not contain whitespace, quotes or angle brackets"]

      uri.scheme != "https" or uri.host in [nil, ""] ->
        ["widget/0 script_url must be an https:// URL, got #{inspect(url)}"]

      uri.userinfo != nil ->
        ["widget/0 script_url must not carry credentials"]

      uri.fragment != nil ->
        ["widget/0 script_url must not carry a fragment (#)"]

      not Enum.any?(script_src, &covers?(&1, uri)) ->
        [
          "widget/0 script_url #{inspect(url)} is not covered by any csp_sources/0 script_src entry"
        ]

      true ->
        []
    end
  end

  defp script_url_problems(other, _script_src),
    do: ["widget/0 script_url must be a string, got #{inspect(other)}"]

  # CSP source matching for an https source: same host (case-insensitive),
  # same port (443 when absent), and a path that either is absent, ends in
  # `/` and prefixes the URL's path, or equals it.
  defp covers?(source, %URI{} = uri) do
    case Regex.named_captures(@csp_source, source) do
      %{"host" => host, "port" => port, "path" => path} ->
        String.downcase(host) == String.downcase(uri.host) and
          port_number(port) == (uri.port || 443) and path_covers?(path, uri.path || "/")

      nil ->
        false
    end
  end

  defp port_number(""), do: 443
  defp port_number(port), do: String.to_integer(port)

  defp path_covers?("", _path), do: true

  defp path_covers?(source_path, path) do
    if String.ends_with?(source_path, "/"),
      do: String.starts_with?(path, source_path),
      else: path == source_path
  end

  defp pattern_problems(_key, nil, _pattern, true = _optional?), do: []

  defp pattern_problems(key, value, pattern, _optional?) when is_binary(value) do
    if Regex.match?(pattern, value),
      do: [],
      else: ["widget/0 #{key} #{inspect(value)} is not a valid name"]
  end

  defp pattern_problems(key, value, _pattern, _optional?),
    do: ["widget/0 #{key} must be a string, got #{inspect(value)}"]

  defp api_problems(:explicit_render), do: []

  defp api_problems(other),
    do: ["widget/0 api must be :explicit_render (the only kind supported), got #{inspect(other)}"]

  defp render_options_problems(options) when is_map(options) do
    reserved =
      for key <- Map.keys(options), key in @reserved_options do
        "widget/0 render_options must not set #{inspect(key)}: KilnCMS sets it"
      end

    if json_object?(options),
      do: reserved,
      else: reserved ++ ["widget/0 render_options must be JSON-safe, with string keys"]
  end

  defp render_options_problems(other),
    do: ["widget/0 render_options must be a map, got #{inspect(other)}"]

  defp json_object?(map) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json?(value) end)

  defp json_object?(_other), do: false

  defp json?(value) when is_nil(value) or is_boolean(value) or is_binary(value), do: true
  defp json?(value) when is_integer(value), do: true
  defp json?(value) when is_float(value), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_map(value), do: json_object?(value)
  defp json?(_value), do: false

  defp interactive_problems(value) when is_boolean(value), do: []

  defp interactive_problems(other),
    do: ["widget/0 interactive must be a boolean, got #{inspect(other)}"]

  defp problem(callback, {:raised, _name, message}, _expected),
    do: "#{callback} raised: #{message}"

  defp problem(callback, {:ok, value}, expected),
    do: "#{callback} must return #{expected}, got #{inspect(value)}"
end
