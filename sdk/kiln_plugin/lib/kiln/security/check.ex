defmodule Kiln.Security.Check do
  @moduledoc """
  The contract for a **security posture check** (kiln_cms#2252): one line on
  the console's Security posture page, saying whether a setting that matters
  for security is on, and what to do if it is not.

  KilnCMS ships its own checks (two-factor coverage, the idle timeout, the
  admin allowlist, transport security, …). A plugin adds one from its entry
  module:

      @impl Kiln.Plugin
      def security_checks, do: [MyPlugin.WebhookSecretCheck]

      defmodule MyPlugin.WebhookSecretCheck do
        use Kiln.Security.Check

        @impl Kiln.Security.Check
        def id, do: "my_plugin.webhook_secret"

        @impl Kiln.Security.Check
        def title, do: "Webhook signing secret"

        @impl Kiln.Security.Check
        def scope, do: :deployment

        @impl Kiln.Security.Check
        def run(_context) do
          if Application.get_env(:my_plugin, :webhook_secret) in [nil, ""],
            do: fail("Incoming webhooks are not signed.", facts: %{signed: false}),
            else: pass("Incoming webhooks are signed.", facts: %{signed: true})
        end
      end

  ## The callbacks

    * `c:id/0` — a dotted machine name, lowercase: the plugin's name, a dot,
      then the check's (`"my_plugin.webhook_secret"`). Ids starting `core.`
      are KilnCMS's own; a plugin's is ignored.
    * `c:title/0` — a short name for the row.
    * `c:scope/0` — `:site` when the answer depends on the site being looked
      at (its own settings, its own people), shown to that site's
      administrators; `:deployment` when it is about the whole installation,
      shown only to platform administrators.
    * `c:run/1` — the check itself, given a `Kiln.Security.Check.Context`; it
      answers a `Kiln.Security.Check.Result`, built with the helpers below.
    * `c:description/0` (optional) — a sentence or two on why it matters,
      shown when the row is opened.
    * `c:timeout/0` (optional) — how long `c:run/1` may take, in
      milliseconds. Defaults to 1000; the core holds it between 100 and 5000.

  `c:id/0`, `c:title/0`, `c:scope/0`, `c:description/0` and `c:timeout/0` are
  read every time the page is drawn, outside the deadline: they must return
  constants and must not block.

  ## Answering

  `use Kiln.Security.Check` imports `pass/2`, `warn/2`, `fail/2`, `unknown/2`
  and `n_a/2`. Each takes a one-sentence summary and these options:

    * `:details` — up to ten short strings shown when the row is opened;
    * `:fix_path` — a console path that fixes it (`"/editor/..."`);
    * `:docs_url` — an `https://` page that explains it;
    * `:facts` — a small map of machine-readable values.

  Answer `unknown/2` when the check cannot tell (a setting that could not be
  read), never `pass/2`: the page counts an unknown as a warning. Answer
  `n_a/2` when the check does not apply.

  The summary and details are shown as written: translate them yourself,
  using `t:Kiln.Security.Check.Context.t/0`'s `locale`. **Facts must never
  carry a secret, a token or a person's address**: a later release may publish
  them to monitoring tools.

  ## How the core runs it

  Every check runs at once, each in its own process, each under its own
  deadline. A check that raises, throws, exits, answers something that is not
  a result, or runs past its deadline is shown as "could not run" (never as a
  pass), and the rest of the page is unaffected. The reason is logged on the
  server, not shown.

  The deadline kills the check's own process. Work it hands to another
  process (a `Task` it starts, a message to a `GenServer`) is not killed with
  it, so keep the work inside `c:run/1`, and bound any call you make.

  ## Conformance

  `conformance/1` checks a module against the callbacks above without calling
  `c:run/1`, and names every problem. The core runs it before using a check,
  `mix kiln.plugins.doctor` runs it for every installed one, and a plugin's
  own test can too:

      assert Kiln.Security.Check.conformance(MyPlugin.WebhookSecretCheck) == :ok

  Within 1.x the rules only ever loosen: a check that conforms today keeps
  conforming.
  """

  alias Kiln.Security.Check.Context
  alias Kiln.Security.Check.Result

  @doc "A dotted, lowercase machine name, such as `\"my_plugin.webhook_secret\"`."
  @callback id() :: String.t()

  @doc "A short name for the row."
  @callback title() :: String.t()

  @doc "`:site` (one site's settings) or `:deployment` (the whole installation)."
  @callback scope() :: :site | :deployment

  @doc "The check itself."
  @callback run(Context.t()) :: Result.t()

  @doc "Why it matters, shown when the row is opened."
  @callback description() :: String.t()

  @doc "How long `c:run/1` may take, in milliseconds (default 1000, held to 100..5000)."
  @callback timeout() :: pos_integer()

  @optional_callbacks description: 0, timeout: 0

  @id ~r/\A[a-z][a-z0-9_]*(\.[a-z0-9_]+)+\z/
  @max_id 64
  @max_title 120
  @max_description 1000
  @default_timeout 1000

  @typedoc "A check as `describe/1` resolves it: every default filled in."
  @type description :: %{
          module: module(),
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          scope: :site | :deployment,
          timeout: pos_integer()
        }

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.Security.Check

      import Kiln.Security.Check,
        only: [
          pass: 1,
          pass: 2,
          warn: 1,
          warn: 2,
          fail: 1,
          fail: 2,
          unknown: 1,
          unknown: 2,
          n_a: 1,
          n_a: 2
        ]
    end
  end

  @doc "The check passed."
  @spec pass(String.t(), keyword()) :: Result.t()
  def pass(summary, opts \\ []), do: Result.new(:pass, summary, opts)

  @doc "Something should be changed, but nothing is exposed."
  @spec warn(String.t(), keyword()) :: Result.t()
  def warn(summary, opts \\ []), do: Result.new(:warn, summary, opts)

  @doc "Something is exposed and should be fixed first."
  @spec fail(String.t(), keyword()) :: Result.t()
  def fail(summary, opts \\ []), do: Result.new(:fail, summary, opts)

  @doc "The check could not tell. Counted as a warning, never as a pass."
  @spec unknown(String.t(), keyword()) :: Result.t()
  def unknown(summary, opts \\ []), do: Result.new(:unknown, summary, opts)

  @doc "The check does not apply here."
  @spec n_a(String.t(), keyword()) :: Result.t()
  def n_a(summary, opts \\ []), do: Result.new(:n_a, summary, opts)

  @doc "The deadline a check gets when it does not say (`c:timeout/0`), in milliseconds."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  `:ok` when `module` is a usable check, or `{:error, problems}` naming every
  way it is not. Calls every callback but `c:run/1`; one that raises is a
  problem, never a crash.
  """
  @spec conformance(module()) :: :ok | {:error, [String.t()]}
  def conformance(module) do
    case describe(module) do
      {:ok, _description} -> :ok
      {:error, problems} -> {:error, problems}
    end
  end

  @doc """
  `module` resolved for use: `{:ok, description}` with `c:description/0` and
  `c:timeout/0` filled in (`nil` and #{@default_timeout} when absent), or
  `{:error, problems}` as `conformance/1` reports them. The timeout is the
  check's own; the core clamps it.
  """
  @spec describe(module()) :: {:ok, description()} | {:error, [String.t()]}
  def describe(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and implements?(module) do
      {id, id_problems} = check_id(call(module, :id))
      {title, title_problems} = check_title(call(module, :title))
      {scope, scope_problems} = check_scope(call(module, :scope))
      {description, description_problems} = check_description(module)
      {timeout, timeout_problems} = check_timeout(module)

      case id_problems ++
             title_problems ++
             scope_problems ++
             description_problems ++
             timeout_problems do
        [] ->
          {:ok,
           %{
             module: module,
             id: id,
             title: title,
             description: description,
             scope: scope,
             timeout: timeout
           }}

        problems ->
          {:error, problems}
      end
    else
      {:error, ["#{inspect(module)} does not implement Kiln.Security.Check"]}
    end
  end

  def describe(other), do: {:error, ["#{inspect(other)} is not a module"]}

  defp implements?(module) do
    Enum.all?(
      [id: 0, title: 0, scope: 0, run: 1],
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
    if Regex.match?(@id, id) and byte_size(id) <= @max_id,
      do: {id, []},
      else:
        {nil,
         [
           "id/0 must be dotted lowercase segments of a-z, 0-9 or _ " <>
             "(\"my_plugin.check_name\", at most #{@max_id} characters), got #{inspect(id)}"
         ]}
  end

  defp check_id(other), do: {nil, [problem("id/0", other, "a string")]}

  defp check_title({:ok, title}) when is_binary(title) do
    if String.trim(title) != "" and String.length(title) <= @max_title,
      do: {title, []},
      else: {nil, ["title/0 must be a non-empty string of at most #{@max_title} characters"]}
  end

  defp check_title(other), do: {nil, [problem("title/0", other, "a non-empty string")]}

  defp check_scope({:ok, scope}) when scope in [:site, :deployment], do: {scope, []}
  defp check_scope(other), do: {nil, [problem("scope/0", other, ":site or :deployment")]}

  defp check_description(module) do
    if function_exported?(module, :description, 0),
      do: described(call(module, :description)),
      else: {nil, []}
  end

  defp described({:ok, text}) when is_binary(text) do
    if String.length(text) <= @max_description,
      do: {text, []},
      else: {nil, ["description/0 must be at most #{@max_description} characters"]}
  end

  defp described(other), do: {nil, [problem("description/0", other, "a string")]}

  defp check_timeout(module) do
    if function_exported?(module, :timeout, 0) do
      case call(module, :timeout) do
        {:ok, ms} when is_integer(ms) and ms > 0 -> {ms, []}
        other -> {nil, [problem("timeout/0", other, "a positive integer of milliseconds")]}
      end
    else
      {@default_timeout, []}
    end
  end

  defp problem(callback, {:raised, _name, message}, _expected),
    do: "#{callback} raised: #{message}"

  defp problem(callback, {:ok, value}, expected),
    do: "#{callback} must return #{expected}, got #{inspect(value)}"
end
