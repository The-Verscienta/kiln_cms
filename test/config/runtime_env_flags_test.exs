defmodule KilnCMS.Config.RuntimeEnvFlagsTest do
  @moduledoc """
  Pins how `config/runtime.exs` reads its boolean environment variables (#607),
  and in particular that `DATABASE_SSL=True` encrypts the Postgres connection
  (#606).

  `KilnCMS.Config.EnvTest` covers the parser in isolation; these evaluate the
  real config file, so they also catch a call site that stops using the parser —
  which is exactly how the original defect arose. The `DATABASE_SSL` case is not
  a spelling nicety: matching the raw value sent `True` to `false`, so an
  operator explicitly asking for TLS got credentials and every query in the
  clear, with no warning and no boot failure.

  This file absorbed the former `runtime_audit_flag_test.exs` (#605), which
  covered `KILN_AUDIT_ANCHOR_EVERY_WRITE` alone with its own copy of this
  harness. Everything unique to it — the `:test`-env skip, `:not_written` being
  distinct from a written `false`, and the warning reaching stderr through the
  real config path — is in the `KILN_AUDIT_ANCHOR_EVERY_WRITE` block below.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # runtime.exs's :prod branch reads these and raises without them.
  @prod_env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("y", 64)
  }

  # Every var these tests touch, so each case starts from a known-clean slate
  # rather than inheriting the developer's shell or a previous case — and, just
  # as importantly, so the suite that runs after them does too. The file this
  # replaced set @prod_env and never restored it.
  #
  # The last five are listed for a reason specific to the `:config_warnings`
  # cases (#634): those assert the collected list is EXACTLY empty, and every
  # variable runtime.exs reads through `Env` under `:prod` can add an entry. A
  # developer with `OEMBED_ENABLED=enabled` exported would otherwise get a red
  # suite with an assertion message naming DATABASE_SSL.
  #
  # KILN_UPDATE_REPO/RELEASES_URL/PIN_PATH are listed although no case sets
  # them: they write into the *same* `Kiln.Updates` keyword the update-check
  # cases assert on, and `Config` deep-merges — so a fork maintainer, whom
  # docs/environment-variables.md instructs to set KILN_UPDATE_REPO, would
  # otherwise get a red suite for a reason unrelated to what is asserted.
  @vars ~w(
            DATABASE_SSL DATABASE_SSL_CACERTFILE ECTO_IPV6 PHX_SERVER
            VISUAL_EDITING_ENABLED KILN_UPDATE_CHECK KILN_ANALYTICS_REFERRERS
            KILN_ANALYTICS_LOW_COUNT_THRESHOLD
            KILN_AUDIT_ANCHORS_ENABLED KILN_AUDIT_ANCHOR_EVERY_WRITE
            KILN_UPDATE_REPO KILN_UPDATE_RELEASES_URL KILN_PIN_PATH
            MAIL_MODE SMTP_HOST SMTP_TLS SMTP_TLS_VERIFY S3_BUCKET
            KILN_PROVENANCE_ENABLED TENANT_STRICT_HOST API_DOCS_ENABLED
            BACKUP_ENABLED OEMBED_ENABLED
            KILN_READING_TIME_WPM BACKUP_KEEP_DAYS BACKUP_STALE_AFTER_HOURS
            KILN_EXPERIMENTS_STICKY_DAYS REQUIRE_AV_METADATA_STRIP
            BRAND_PRIMARY_COLOR ASK_RERANK
          ) ++ Map.keys(@prod_env)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  # Evaluate runtime.exs the way a release does; return the resulting config.
  # Warnings from deliberately unrecognized values are captured, not printed.
  defp eval(vars, env \\ :prod), do: elem(eval_io(vars, env), 0)

  # As `eval/2`, but also returns whatever runtime.exs wrote to stderr — the
  # only observable difference between "kept the default because unset" and
  # "kept the default because the value made no sense".
  defp eval_io(vars, env) do
    # Clear first, so each evaluation sees exactly `vars` and nothing else. The
    # setup block restores the developer's shell afterwards, but during a case
    # an exported `DATABASE_SSL=require` would otherwise add its own warning to
    # the captured stderr that another case's assertion reads.
    Enum.each(@vars, &System.delete_env/1)
    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)

    Enum.each(vars, fn
      {var, nil} -> System.delete_env(var)
      {var, value} -> System.put_env(var, value)
    end)

    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        send(parent, {:config, Config.Reader.read!(@runtime, env: env)})
      end)

    receive do
      {:config, config} -> {config, stderr}
    after
      0 -> flunk("runtime.exs did not evaluate")
    end
  end

  defp repo_ssl(value) do
    %{"DATABASE_SSL" => value} |> eval() |> get_in([:kiln_cms, KilnCMS.Repo, :ssl])
  end

  describe "DATABASE_SSL (#606)" do
    test "unset encrypts — the safe default is unchanged" do
      assert repo_ssl(nil) == true
    end

    test "every on-spelling encrypts, whatever the case or padding" do
      # The regression: `True`, `TRUE` and `" true "` all fell through to
      # `false` and silently downgraded the connection to plaintext.
      for value <- ["true", "True", "TRUE", " true ", "1", "yes", "on", "On"] do
        assert repo_ssl(value) == true,
               "DATABASE_SSL=#{inspect(value)} must not disable Postgres TLS"
      end
    end

    test "an explicit off-spelling still disables it, for providers without TLS" do
      for value <- ["false", "False", "0", "no", "off", "OFF"] do
        assert repo_ssl(value) == false
      end
    end

    test "an unrecognized value keeps TLS on and warns, rather than downgrading" do
      for value <- ["enabled", ~s("true"), "y", "maybe"] do
        assert repo_ssl(value) == true,
               "DATABASE_SSL=#{inspect(value)} must not be read as a request for plaintext"
      end
    end

    test "ssl_opts are attached whenever TLS is on, and omitted when it is off" do
      # Regression guard for the `++ if(database_ssl?, ...)` tail: a mismatch
      # between the `ssl:` flag and `ssl_opts:` would either error at connect
      # or silently drop peer verification.
      on = eval(%{"DATABASE_SSL" => "True"}) |> get_in([:kiln_cms, KilnCMS.Repo])
      assert on[:ssl] == true
      assert on[:ssl_opts] == [verify: :verify_none]

      off = eval(%{"DATABASE_SSL" => "false"}) |> get_in([:kiln_cms, KilnCMS.Repo])
      assert off[:ssl] == false
      refute Keyword.has_key?(off, :ssl_opts)
    end
  end

  describe "DATABASE_SSL_CACERTFILE" do
    defp ssl_opts(vars), do: vars |> eval() |> get_in([:kiln_cms, KilnCMS.Repo, :ssl_opts])

    test "a path switches on peer verification" do
      opts = ssl_opts(%{"DATABASE_SSL_CACERTFILE" => "/etc/ssl/ca.pem"})

      assert opts[:verify] == :verify_peer
      assert opts[:cacertfile] == "/etc/ssl/ca.pem"
    end

    test "unset falls back to encrypted-but-unverified" do
      assert ssl_opts(%{}) == [verify: :verify_none]
    end

    test "a blank value falls back too, rather than verifying against an empty path" do
      # `DATABASE_SSL_CACERTFILE=` is a routine .env/compose artifact. Matching
      # only `nil` sent it to verify_peer with `cacertfile: ""`, so :ssl failed
      # to read the bundle and every connection died at boot — the opposite of
      # the fallback this branch exists to provide.
      for blank <- ["", " ", "\t"] do
        assert ssl_opts(%{"DATABASE_SSL_CACERTFILE" => blank}) == [verify: :verify_none],
               "DATABASE_SSL_CACERTFILE=#{inspect(blank)} must read as unset"
      end
    end
  end

  describe "PHX_SERVER" do
    defp serves?(value) do
      %{"PHX_SERVER" => value} |> eval() |> get_in([:kiln_cms, KilnCMSWeb.Endpoint, :server])
    end

    test "an explicit off-spelling does not start the server" do
      # The regression: every string is truthy in Elixir, so the generator's
      # bare `if System.get_env("PHX_SERVER")` started the server on `false`.
      # Nothing catches it either way — the release boots, migrates, and answers
      # `bin/kiln_cms rpc`, which is all the Docker healthcheck checks.
      for value <- ["false", "False", "FALSE", "0", "no", "off", " OFF "] do
        refute serves?(value), "PHX_SERVER=#{inspect(value)} must not start the server"
      end
    end

    test "any other value starts it, including blank and unrecognized" do
      # Documented as "any truthy value", and blank is truthy: reading
      # `PHX_SERVER=` as "do not serve HTTP" would be a silent outage on
      # upgrade for anyone whose manifest declares the variable empty.
      for value <- ["true", "1", "yes", "on", "please", "", " "] do
        assert serves?(value) == true, "PHX_SERVER=#{inspect(value)} must start the server"
      end
    end

    test "unset does not start it" do
      refute serves?(nil)
    end
  end

  describe "ECTO_IPV6" do
    defp socket_options(value) do
      %{"ECTO_IPV6" => value}
      |> eval()
      |> get_in([:kiln_cms, KilnCMS.Repo, :socket_options])
    end

    test "unset stays on IPv4" do
      assert socket_options(nil) == []
    end

    test "on-spellings select inet6 regardless of case" do
      for value <- ["true", "TRUE", " 1 ", "yes", "on"] do
        assert socket_options(value) == [:inet6],
               "ECTO_IPV6=#{inspect(value)} should select inet6"
      end
    end

    test "off-spellings and unrecognized values stay on IPv4" do
      for value <- ["false", "Off", "0", "gibberish"] do
        assert socket_options(value) == []
      end
    end
  end

  describe "VISUAL_EDITING_ENABLED" do
    defp visual_editing(value) do
      %{"VISUAL_EDITING_ENABLED" => value}
      |> eval()
      |> get_in([:kiln_cms, :visual_editing_enabled])
    end

    test "unset writes nothing, leaving the compiled default in force" do
      assert visual_editing(nil) == nil
    end

    test "off-spellings disable the bridge in any case" do
      # `False` used to leave the bridge ON, contradicting
      # docs/environment-variables.md, which documents `false`/`0`/`no`/`off`.
      for value <- ["false", "False", "FALSE", " off ", "0", "no", "OFF"] do
        assert visual_editing(value) == false,
               "VISUAL_EDITING_ENABLED=#{inspect(value)} should disable the bridge"
      end
    end

    test "on-spellings enable it explicitly" do
      for value <- ["true", "True", "1", "yes", "On"] do
        assert visual_editing(value) == true
      end
    end

    test "an unrecognized value writes nothing rather than reading as on" do
      assert visual_editing("enabled") == nil
    end
  end

  describe "KILN_UPDATE_CHECK" do
    defp update_check(value) do
      %{"KILN_UPDATE_CHECK" => value}
      |> eval()
      |> get_in([:kiln_cms, Kiln.Updates])
    end

    test "unset writes nothing, so the compiled default (enabled) stands" do
      updates = update_check(nil)
      assert updates == nil or not Keyword.has_key?(updates, :enabled)
    end

    test "off-spellings disable the outbound check in any case" do
      for value <- ["false", "FALSE", "Off", "0", "no"] do
        assert update_check(value)[:enabled] == false,
               "KILN_UPDATE_CHECK=#{inspect(value)} should stop the outbound request"
      end
    end

    test "on-spellings enable it explicitly, overriding an overlay that turned it off" do
      assert update_check("True")[:enabled] == true
    end

    test "an unrecognized value leaves the setting alone" do
      updates = update_check("nope")
      assert updates == nil or not Keyword.has_key?(updates, :enabled)
    end
  end

  describe "KILN_ANALYTICS_REFERRERS (#619)" do
    defp analytics_referrers(value) do
      %{"KILN_ANALYTICS_REFERRERS" => value}
      |> eval()
      |> get_in([:kiln_cms, :analytics_referrers])
    end

    test "unset writes nothing, so the compiled default (disabled) stands" do
      referrers = analytics_referrers(nil)
      assert referrers == nil or not Keyword.has_key?(referrers, :enabled)
    end

    test "on-spellings enable it in any case" do
      for value <- ["true", "True", "1", "yes", "On"] do
        assert analytics_referrers(value)[:enabled] == true,
               "KILN_ANALYTICS_REFERRERS=#{inspect(value)} should enable referrer attribution"
      end
    end

    test "off-spellings leave it disabled, explicitly" do
      for value <- ["false", "FALSE", "Off", "0", "no"] do
        assert analytics_referrers(value)[:enabled] == false
      end
    end

    test "an unrecognized value leaves the setting alone" do
      referrers = analytics_referrers("enabled")
      assert referrers == nil or not Keyword.has_key?(referrers, :enabled)
    end
  end

  describe "KILN_ANALYTICS_LOW_COUNT_THRESHOLD (#620)" do
    # Not a boolean, but it does go through KilnCMS.Config.Env since #1009 —
    # `Env.positive_integer/1`, the same shared reader as KILN_READING_TIME_WPM
    # and the two `BACKUP_*` counts, which each used to hand-roll the parse.
    defp low_count_threshold(value) do
      {config, stderr} = eval_io(%{"KILN_ANALYTICS_LOW_COUNT_THRESHOLD" => value}, :prod)
      {get_in(config, [:kiln_cms, :analytics_referrers, :low_count_threshold]), stderr}
    end

    test "unset writes nothing, so the compiled default (5) stands" do
      assert {nil, _stderr} = low_count_threshold(nil)
    end

    test "a positive integer is written" do
      assert {12, _stderr} = low_count_threshold("12")
    end

    test "surrounding whitespace is trimmed" do
      assert {7, _stderr} = low_count_threshold("  7  ")
    end

    test "zero, a negative number, or a non-integer value keeps the default and warns" do
      for value <- ["0", "-1", "five", "3.5", "7 days"] do
        {threshold, stderr} = low_count_threshold(value)

        assert threshold == nil,
               "KILN_ANALYTICS_LOW_COUNT_THRESHOLD=#{inspect(value)} must not be interpreted"

        assert stderr =~ "KILN_ANALYTICS_LOW_COUNT_THRESHOLD is set to",
               "#{inspect(value)} should warn rather than be silently swallowed"

        assert stderr =~ "not a positive integer"
      end
    end

    test "blank reads as unset and warns about nothing (#1009)" do
      # This changed with the shared reader: the hand-rolled parse here treated
      # `VAR=` as a bad value and warned. `Env.fetch/1` has always read blank as
      # unset, and `VAR=` in a compose file is how an operator writes "leave
      # this alone" — warning about it is noise on every boot. Either way the
      # default stands, so only the warning differs.
      for value <- ["", " ", "\t"] do
        assert {nil, stderr} = low_count_threshold(value)
        refute stderr =~ "KILN_ANALYTICS_LOW_COUNT_THRESHOLD"
      end
    end

    test "it deep-merges with KILN_ANALYTICS_REFERRERS rather than clobbering it" do
      config =
        eval(%{"KILN_ANALYTICS_REFERRERS" => "true", "KILN_ANALYTICS_LOW_COUNT_THRESHOLD" => "3"})

      referrers = get_in(config, [:kiln_cms, :analytics_referrers])
      assert referrers[:enabled] == true
      assert referrers[:low_count_threshold] == 3
    end
  end

  describe "ASK_RERANK (the Shen-beat-Huang-Qi report, P7)" do
    # The ask-only reranking switch. Read with `fetch/1` so that an unset
    # variable writes nothing — a project overlay's `config :kiln_cms,
    # KilnCMS.Ask, rerank: true` must survive a deploy that never mentions
    # the variable, and an explicit `false` must be able to switch it off.
    defp ask_rerank(value, env \\ :prod) do
      {config, stderr} = eval_io(%{"ASK_RERANK" => value}, env)

      written =
        case get_in(config, [:kiln_cms, KilnCMS.Ask, :rerank]) do
          nil -> :not_written
          bool -> bool
        end

      {written, stderr}
    end

    test "on-spellings enable it, in any case and with surrounding space" do
      for value <- ["true", "TRUE", " true ", "1", "yes", "on"] do
        assert {true, _} = ask_rerank(value), "expected #{inspect(value)} to enable it"
      end
    end

    test "off-spellings write an explicit false, so an overlay's true can be overridden" do
      for value <- ["false", "False", " off ", "0", "no"] do
        assert {false, _} = ask_rerank(value), "expected #{inspect(value)} to disable it"
      end
    end

    test "unset writes nothing, leaving a project overlay's setting in force" do
      assert {:not_written, _} = ask_rerank(nil)
    end

    test "an unrecognized value writes nothing and warns, instead of reading as on" do
      for value <- ["enabled", "y", "maybe"] do
        {written, stderr} = ask_rerank(value)
        assert written == :not_written, "#{inspect(value)} must keep the default"
        assert stderr =~ "ASK_RERANK is set to an unrecognized value"
      end
    end

    test "the block is skipped under :test so the suite is deterministic" do
      assert {:not_written, _} = ask_rerank("true", :test)
    end
  end

  describe "KILN_AUDIT_ANCHORS_ENABLED (#356/#611)" do
    # The master switch: `Chain.extend/2` requires this AND every_write, so
    # before this variable existed there was no runtime way back once the
    # compiled default was flipped off — a documented "no rebuild needed" kill
    # switch that in fact needed one (#611).
    defp anchors_enabled(value, env \\ :prod) do
      {config, stderr} = eval_io(%{"KILN_AUDIT_ANCHORS_ENABLED" => value}, env)

      written =
        case get_in(config, [:kiln_cms, :audit_anchors_enabled]) do
          nil -> :not_written
          bool -> bool
        end

      {written, stderr}
    end

    test "on-spellings enable it, in any case and with surrounding space" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert {true, _} = anchors_enabled(value), "expected #{inspect(value)} to enable it"
      end
    end

    test "off-spellings disable it, in any case" do
      for value <- ["false", "FALSE", "False", " off ", "0", "no", "NO", "OFF"] do
        assert {false, _} = anchors_enabled(value), "expected #{inspect(value)} to disable it"
      end
    end

    test "unset writes nothing, leaving the compiled default (true) in force" do
      assert {:not_written, _} = anchors_enabled(nil)
    end

    test "an unrecognized value writes nothing and warns, instead of reading as on" do
      for value <- ["enabled", "y", "t", "True!", ~s("true"), "maybe"] do
        {written, stderr} = anchors_enabled(value)

        assert written == :not_written,
               "#{inspect(value)} must not be interpreted — it should keep the default"

        assert stderr =~ "KILN_AUDIT_ANCHORS_ENABLED is set to an unrecognized value",
               "#{inspect(value)} should warn rather than be silently swallowed"
      end
    end

    test "a recognized value warns about nothing" do
      {_written, stderr} = anchors_enabled("false")
      refute stderr =~ "KILN_AUDIT_ANCHORS_ENABLED is set to an unrecognized value"
    end

    test "the block is skipped under :test so the suite is deterministic" do
      assert {:not_written, _} = anchors_enabled("false", :test)
    end
  end

  describe "KILN_AUDIT_ANCHOR_EVERY_WRITE (#356/#605)" do
    # The flag decides whether every versioned write is signed and anchored, so
    # the direction it fails in matters. `:not_written` is distinct from a
    # written `false`: the former keeps whatever the compiled config (or a
    # project overlay) chose, the latter overrides it.
    defp anchor_every_write(value, env \\ :prod) do
      {config, stderr} = eval_io(%{"KILN_AUDIT_ANCHOR_EVERY_WRITE" => value}, env)

      written =
        case get_in(config, [:kiln_cms, :audit_anchor_every_write]) do
          nil -> :not_written
          bool -> bool
        end

      {written, stderr}
    end

    test "on-spellings enable it, in any case and with surrounding space" do
      for value <- ["true", "TRUE", "True", " true ", "1", "yes", "YES", "on", "On"] do
        assert {true, _} = anchor_every_write(value), "expected #{inspect(value)} to enable it"
      end
    end

    test "off-spellings disable it, in any case" do
      for value <- ["false", "FALSE", "False", " off ", "0", "no", "NO", "OFF"] do
        assert {false, _} = anchor_every_write(value), "expected #{inspect(value)} to disable it"
      end
    end

    test "unset writes nothing, leaving the compiled default in force" do
      assert {:not_written, _} = anchor_every_write(nil)
    end

    test "an unrecognized value writes nothing and warns, instead of reading as off" do
      # The regression this pins: a bare `!= ""` guard sent every typo to
      # `false`, silently disabling an audit trail a deployment had enabled.
      for value <- ["enabled", "y", "t", "True!", ~s("true"), "maybe"] do
        {written, stderr} = anchor_every_write(value)

        assert written == :not_written,
               "#{inspect(value)} must not be interpreted — it should keep the default"

        # Named, not just "unrecognized value": this evaluates the whole
        # runtime.exs, and the sibling KILN_PROVENANCE_ENABLED block emits the
        # same phrase — so a garbage value exported for that var would otherwise
        # satisfy this assertion, or fail the one below.
        assert stderr =~ "KILN_AUDIT_ANCHOR_EVERY_WRITE is set to an unrecognized value",
               "#{inspect(value)} should warn rather than be silently swallowed"
      end
    end

    test "a recognized value warns about nothing" do
      {_written, stderr} = anchor_every_write("true")
      refute stderr =~ "KILN_AUDIT_ANCHOR_EVERY_WRITE is set to an unrecognized value"
    end

    test "the block is skipped under :test so the suite is deterministic" do
      # The var is advertised in .env.example; a developer exporting it must not
      # change how the governance tests behave.
      assert {:not_written, _} = anchor_every_write("true", :test)
    end
  end

  # #634. The stderr line above is the only signal an operator gets that a flag
  # did not take effect, and in a release it reaches container stdout and nothing
  # else. These pin the handoff that lets `KilnCMS.Application` replay it through
  # `Logger` — the end-to-end half of `KilnCMS.Config.EnvTest`'s unit coverage,
  # through the real `Config.Reader` path a release actually takes.
  # #1009: four variables had each hand-rolled `Integer.parse` + a positivity
  # check + an `IO.warn`. Only one of the four had any test at all, which is how
  # they were free to disagree — and none of the four registered with the
  # collector, so a mistyped count warned on container stdout and reached
  # neither Logger nor Sentry (#634). These pin all four through the real file.
  describe "positive-integer variables (#1009)" do
    @counts [
      {"KILN_READING_TIME_WPM", [:kiln_cms, :reading_time_wpm]},
      {"KILN_ANALYTICS_LOW_COUNT_THRESHOLD",
       [:kiln_cms, :analytics_referrers, :low_count_threshold]},
      {"BACKUP_KEEP_DAYS", [:kiln_cms, KilnCMS.Backups, :keep_days]},
      {"BACKUP_STALE_AFTER_HOURS", [:kiln_cms, KilnCMS.Backups, :stale_after_hours]},
      {"KILN_EXPERIMENTS_STICKY_DAYS", [:kiln_cms, KilnCMS.Experiments, :sticky_max_age_days]}
    ]

    test "each reads a positive integer, and trims" do
      for {var, path} <- @counts do
        assert get_in(eval(%{var => " 7 "}), path) == 7,
               "#{var} did not read a positive integer through the shared reader"
      end
    end

    test "zero and unparseable values are refused by every one of them" do
      # The four used to differ here in principle — this is the assertion that
      # keeps a fifth call site, or an edit to one of these four, from drifting.
      for {var, path} <- @counts, value <- ["0", "-1", "seven", "7 days"] do
        {config, stderr} = eval_io(%{var => value}, :prod)

        refute get_in(config, path) == 0
        assert stderr =~ var, "#{var}=#{inspect(value)} was swallowed without a warning"
        assert stderr =~ "not a positive integer"
      end
    end

    test "a refused count reaches :config_warnings, tagged as a count" do
      # This is the part that did not work before: the hand-rolled `IO.warn`
      # wrote to stderr and stopped there, so the #634 replay — the only path to
      # Logger and Sentry — never saw a mistyped count.
      for {var, _path} <- @counts do
        assert {^var, "7 days", :positive_integer} =
                 %{var => "7 days"}
                 |> eval(:prod)
                 |> get_in([:kiln_cms, :config_warnings])
                 |> Enum.find(&(elem(&1, 0) == var)),
               "#{var} did not reach the :config_warnings handoff"
      end
    end

    test "the backup counts keep their documented defaults when refused" do
      # `BACKUP_KEEP_DAYS=0` read literally would delete every backup it had
      # just taken; falling back to 14 is the entire point of refusing it.
      {config, _stderr} = eval_io(%{"BACKUP_KEEP_DAYS" => "0"}, :prod)
      assert get_in(config, [:kiln_cms, KilnCMS.Backups, :keep_days]) == 14

      {config, _stderr} = eval_io(%{"BACKUP_STALE_AFTER_HOURS" => "nope"}, :prod)
      assert get_in(config, [:kiln_cms, KilnCMS.Backups, :stale_after_hours]) == 36
    end

    test "blank reads as unset for every one of them, silently" do
      for {var, _path} <- @counts do
        {config, stderr} = eval_io(%{var => ""}, :prod)

        refute stderr =~ var
        assert get_in(config, [:kiln_cms, :config_warnings]) == []
      end
    end
  end

  # #1089: this used to be validated only in `KilnCMS.Branding`, whose rejection
  # is a bare `Logger.warning` — dropped by `Sentry.LoggerHandler`'s defaults, so
  # container stdout and nowhere else, for a value that changes what every page
  # looks like.
  describe "BRAND_PRIMARY_COLOR (#48, #1089)" do
    defp brand_color(value),
      do:
        %{"BRAND_PRIMARY_COLOR" => value}
        |> eval()
        |> get_in([:kiln_cms, :branding, :primary_color])

    test "a hex colour is written, normalized to the canonical form" do
      # Shorthand expansion and downcasing happen once here rather than on every
      # render, and mean the value echoed back on a later warning matches what
      # the theme tokens were built from.
      assert brand_color("#1d4ed8") == "#1d4ed8"
      assert brand_color("#1D4ED8") == "#1d4ed8"
      assert brand_color("#1d4") == "#11dd44"
    end

    test "unset and blank write nothing and warn about nothing" do
      for value <- [nil, "", "   "] do
        {config, stderr} = eval_io(%{"BRAND_PRIMARY_COLOR" => value}, :prod)

        assert get_in(config, [:kiln_cms, :branding, :primary_color]) == nil
        refute stderr =~ "BRAND_PRIMARY_COLOR"

        # Scoped to this variable rather than asserting the whole collector is
        # empty: the list is shared with every other variable runtime.exs reads
        # under :prod, so a future default that records a warning would fail
        # this case with a message pointing at branding.
        refute Enum.any?(
                 get_in(config, [:kiln_cms, :config_warnings]),
                 &match?({"BRAND_PRIMARY_COLOR", _, _}, &1)
               )
      end
    end

    test "a value that is not a hex colour is dropped, warned about, and COLLECTED" do
      # The collection is the point of #1089 — a stderr line alone is the
      # failure mode #634 exists to close.
      for value <- ["blue", "1d4ed8", "#12345", "#1d4ed8; content:", "rgb(1,2,3)"] do
        {config, stderr} = eval_io(%{"BRAND_PRIMARY_COLOR" => value}, :prod)

        assert get_in(config, [:kiln_cms, :branding, :primary_color]) == nil,
               "#{inspect(value)} must not reach the theme tokens"

        assert stderr =~ "BRAND_PRIMARY_COLOR"

        assert {"BRAND_PRIMARY_COLOR", value, {:expected, "a hex colour such as #1d4ed8 or #1d4"}} in get_in(
                 config,
                 [:kiln_cms, :config_warnings]
               )
      end
    end

    test "the collected value is what the operator typed, not a trimmed form" do
      {config, _stderr} = eval_io(%{"BRAND_PRIMARY_COLOR" => "  blue  "}, :prod)

      assert {"BRAND_PRIMARY_COLOR", "  blue  ", _} =
               config
               |> get_in([:kiln_cms, :config_warnings])
               |> Enum.find(&match?({"BRAND_PRIMARY_COLOR", _, _}, &1))
    end
  end

  describe ":config_warnings handoff (#634)" do
    defp config_warnings(vars, env \\ :prod),
      do: vars |> eval(env) |> get_in([:kiln_cms, :config_warnings])

    test "an unrecognized value is carried out of runtime.exs, not just warned about" do
      warnings = config_warnings(%{"DATABASE_SSL" => "enabled"})

      assert {"DATABASE_SSL", "enabled", :boolean} in warnings
    end

    test "the raw value survives, not the normalized form" do
      # Same reason the stderr line quotes it: the trimming and downcasing are
      # what caused the mismatch, so the normalized string is the one the
      # operator cannot find in their compose file.
      assert {"DATABASE_SSL", " Enabled ", :boolean} in config_warnings(%{
               "DATABASE_SSL" => " Enabled "
             })
    end

    test "several bad values are all carried, not just the first" do
      warnings =
        config_warnings(%{"DATABASE_SSL" => "enabled", "VISUAL_EDITING_ENABLED" => "ture"})

      assert {"DATABASE_SSL", "enabled", :boolean} in warnings
      assert {"VISUAL_EDITING_ENABLED", "ture", :boolean} in warnings
    end

    test "a clean boot writes an empty list, not nil" do
      # `KilnCMS.Application` defaults to `[]`, but writing the key
      # unconditionally is what stops `Config`'s deep merge leaving a previous
      # evaluation's list in place on the config-provider path.
      assert config_warnings(%{"DATABASE_SSL" => "true"}) == []
    end

    test "a second evaluation in the same process does not inherit the first's warnings" do
      # `Config.Reader.read!/2` runs in the calling process, so the collector
      # would otherwise accumulate across evaluations and report a variable the
      # operator never set on this pass. `take_collected/0` drains for this.
      assert {"DATABASE_SSL", "enabled", :boolean} in config_warnings(%{
               "DATABASE_SSL" => "enabled"
             })

      assert config_warnings(%{"DATABASE_SSL" => "true"}) == []
    end

    test "it is written in :test too, so a dev boot reports the same way" do
      # `VISUAL_EDITING_ENABLED`, not `DATABASE_SSL`: the latter is only read
      # inside runtime.exs's `:prod` branch, so under `:test` there is nothing to
      # warn about and the assertion would pass for the wrong reason.
      assert {"VISUAL_EDITING_ENABLED", "ture", :boolean} in config_warnings(
               %{"VISUAL_EDITING_ENABLED" => "ture"},
               :test
             )
    end
  end
end
