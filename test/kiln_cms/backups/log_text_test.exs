defmodule KilnCMS.Backups.LogTextTest do
  @moduledoc """
  A backup run's log as the Log tab and the download show it (part of
  #2230): filtered by level with the truncated marker always kept, redacted
  again with the secrets known now, and stripped of characters a terminal
  or a bidi renderer would act on.

  `async: false`: it sets `PGPASSWORD` and the `KilnCMS.Backups` env
  (`:database_url`), both VM-global.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{LogEntry, LogText}

  setup do
    pgpassword = System.get_env("PGPASSWORD")
    backups = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    System.delete_env("PGPASSWORD")

    on_exit(fn ->
      if pgpassword,
        do: System.put_env("PGPASSWORD", pgpassword),
        else: System.delete_env("PGPASSWORD")

      Application.put_env(:kiln_cms, KilnCMS.Backups, backups)
    end)

    :ok
  end

  defp entry(level, step, message),
    do: %LogEntry{at: ~U[2026-11-27 03:17:00.000000Z], level: level, step: step, message: message}

  defp log do
    [
      entry(:info, "dump", "pg_dump started"),
      entry(:warn, "truncated", "12 log entries were dropped to bound the log"),
      entry(:warn, "offsite", "retrying"),
      entry(:error, "offsite", "rclone failed")
    ]
  end

  # A run whose log holds `messages` as written: `Log.cap/1` redacts with
  # the secrets known when it is stored, so a literal the process learns
  # later is still in the row.
  defp run_with_log!(messages, attrs \\ %{}) do
    run =
      %{stamp: "20261127-031700", trigger: "manual", components: [:db]}
      |> Backups.start_run!(actor: Backups.system())

    run
    |> Backups.fail_run!(
      Map.merge(
        %{
          error: "failed",
          log:
            for(
              m <- messages,
              do: %{at: DateTime.utc_now(), level: :error, step: "dump", message: m}
            )
        },
        attrs
      ),
      actor: Backups.system()
    )
  end

  describe "entries/3 by level" do
    test "all keeps every entry, in order" do
      assert log() |> LogText.entries(:all, []) |> Enum.map(& &1.message) ==
               Enum.map(log(), & &1.message)
    end

    test "warn keeps warnings, errors and the truncated marker" do
      assert log() |> LogText.entries(:warn, []) |> Enum.map(& &1.step) ==
               ["truncated", "offsite", "offsite"]
    end

    test "error keeps errors and the truncated marker" do
      assert [%{step: "truncated"}, %{level: :error, message: "rclone failed"}] =
               LogText.entries(log(), :error, [])
    end

    test "counts/1 counts what each filter shows, the marker in each" do
      assert LogText.counts(log()) == %{all: 4, warn: 3, error: 2}
      assert LogText.counts([]) == %{all: 0, warn: 0, error: 0}
    end
  end

  describe "sanitize_display/1" do
    test "replaces ESC and the other C0 controls but keeps tab and newline" do
      assert LogText.sanitize_display("\e[31mred\e[0m\ta\nb\a\b\0") ==
               "\u{FFFD}[31mred\u{FFFD}[0m\ta\nb\u{FFFD}\u{FFFD}\u{FFFD}"
    end

    test "replaces DEL, the C1 controls and a lone carriage return; CRLF becomes LF" do
      assert LogText.sanitize_display("a\x7Fb\u0085c\u009Bd\u0080e") ==
               "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e"

      assert LogText.sanitize_display("one\r\ntwo\rthree") == "one\ntwo\u{FFFD}three"
    end

    test "replaces the bidi overrides and isolates" do
      for char <- [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] do
        assert LogText.sanitize_display("a" <> <<char::utf8>> <> "b") == "a\u{FFFD}b"
      end

      # Neighbours that aren't overrides stay.
      assert LogText.sanitize_display("a\u2029b\u206Ac") == "a\u2029b\u206Ac"
    end

    test "invalid UTF-8 and non-binaries don't raise" do
      assert LogText.sanitize_display(<<"ok", 0xFF, "\e">>) == "ok\u{FFFD}\u{FFFD}"
      assert LogText.sanitize_display(nil) == ""
    end

    test "entries/3 sanitizes each message and step" do
      [shown] = LogText.entries([entry(:info, "du\emp", "a\e]0;title\ab")], :all, [])
      assert shown.message == "a\u{FFFD}]0;title\u{FFFD}b"
      assert shown.step == "du\u{FFFD}mp"
    end
  end

  describe "render_text/2" do
    test "a header about the run, then one line per entry, every level" do
      run =
        run_with_log!(["first\nsecond line"], %{error: "dump failed\nexit 1"})

      text = LogText.render_text(run, [])

      assert text =~ "# Kiln backup log\n"
      assert text =~ "# Backup: 20261127-031700 (manual, failed)\n"

      assert text =~
               "# Started: " <> DateTime.to_iso8601(DateTime.truncate(run.started_at, :second))

      assert text =~ "# Components: db\n"
      assert text =~ "# Origin: app\n"
      assert text =~ "# Error: dump failed\n#   exit 1\n"
      assert text =~ ~r/\n\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ERROR dump first\n  second line\n\z/
    end

    test "every level and the truncated marker are in it" do
      run = %{run_with_log!([]) | log: log()}
      text = LogText.render_text(run, [])

      assert text =~ "INFO  dump pg_dump started"
      assert text =~ "WARN  truncated 12 log entries were dropped"
      assert text =~ "WARN  offsite retrying"
      assert text =~ "ERROR offsite rclone failed"
    end

    test "an operator's trigger can't start a header line of its own" do
      run = run_with_log!([])
      text = LogText.render_text(%{run | trigger: "cron\n# Error: none"}, [])
      assert text =~ "# Backup: 20261127-031700 (cron # Error: none, failed)\n"
    end

    test "ESC sequences in a message are replaced" do
      text = LogText.render_text(run_with_log!(["\e[2J\e[1;1Hcleared"]), [])
      refute text =~ "\e"
      assert text =~ "\u{FFFD}[2J\u{FFFD}[1;1Hcleared"
    end
  end

  describe "redacted again when read" do
    test "a PGPASSWORD set after the line was stored is removed from entries, error and text" do
      secret = "s3cr3tvalue99"
      run = run_with_log!(["connect with #{secret} failed"], %{error: "bad #{secret}"})

      # Stored as written: nothing knew it then.
      assert hd(run.log).message =~ secret

      System.put_env("PGPASSWORD", secret)

      assert [%{message: message}] = LogText.entries(run, :all)
      refute message =~ secret
      assert message =~ "***"
      refute LogText.error(run) =~ secret
      refute LogText.render_text(run) =~ secret
    end

    test "the DATABASE_URL password is removed with the default env" do
      secret = "DbUrlPw0rd77"
      run = run_with_log!(["auth failed: #{secret}"])
      assert hd(run.log).message =~ secret

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(
          Application.get_env(:kiln_cms, KilnCMS.Backups, []),
          :database_url,
          "postgres://kiln:#{secret}@db.internal/kiln_prod"
        )
      )

      assert {"PGPASSWORD", secret} in LogText.read_env()
      assert [%{message: message}] = LogText.entries(run, :all)
      refute message =~ secret
      refute LogText.render_text(run) =~ secret
    end

    test "pattern secrets are absent end to end" do
      run =
        run_with_log!([
          "password=Hunter2Hunter2",
          "postgres://u:Pw12345678@db/x",
          ":s3,access_key_id=AKIAEXAMPLE,secret_access_key=SuperSecret123:bucket"
        ])

      text = LogText.render_text(run)

      for secret <- ["Hunter2Hunter2", "Pw12345678", "SuperSecret123"] do
        refute text =~ secret
      end

      assert text =~ "***"
    end
  end
end
