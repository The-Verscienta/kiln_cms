defmodule KilnCMS.Backups.ReportTest do
  @moduledoc """
  What a backup report says (#2229): the run's sizes, destinations,
  duration, schedule and first error lines, the links, the class, and
  nothing that is a credential, a control character or a second header line.

  `Report.build/3` is pure, so most runs here are structs built in memory
  with raw text, as a row written before a redaction pattern existed would
  hold it.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.Test.BackupDestinations, only: [fake_config: 2]

  alias KilnCMS.Backups.{Artifact, Destination, LogEntry, Report, ReportMail, Run, RunDestination}
  alias KilnCMS.Types.UnknownAtom

  @at ~U[2026-11-27 03:00:00.000000Z]

  defp run(attrs \\ %{}) do
    struct!(
      Run,
      Map.merge(
        %{
          id: Ash.UUID.generate(),
          stamp: "20261127-030000",
          trigger: "manual",
          status: :succeeded,
          origin: :app,
          components: [:db, :media],
          scheduled_components: [],
          schedule_ids: [],
          started_at: @at,
          finished_at: DateTime.add(@at, 125, :second),
          error: nil,
          log: [],
          artifacts: [],
          destinations: [],
          offsite_status: :none,
          last_failed_at: nil
        },
        attrs
      )
    )
  end

  defp build(run, schedules \\ [], opts \\ []),
    do:
      Report.build(
        run,
        schedules,
        Keyword.merge([env: [], site_name: "Kiln Test", org: nil], opts)
      )

  defp dest(attrs),
    do:
      struct!(
        RunDestination,
        Map.merge(
          %{key: "dest:" <> Ash.UUID.generate(), kind: "s3", label: "Offsite", status: :ok},
          attrs
        )
      )

  defp email_text(email), do: email.subject <> "\n" <> email.html_body <> "\n" <> email.text_body

  describe "content" do
    test "sizes per kind, media parts, verified, duration and components" do
      report =
        build(
          run(%{
            artifacts: [
              %Artifact{
                kind: :db,
                name: "kiln-db-x.dump",
                bytes: 2_048,
                verified: true,
                parts: []
              },
              %Artifact{
                kind: :media,
                name: "kiln-media-x.tar",
                bytes: 3 * 1_048_576,
                verified: true,
                parts: [%{"name" => "p1"}, %{"name" => "p2"}, %{"name" => "p3"}]
              }
            ]
          })
        )

      assert report.class == :succeeded
      assert report.sizes == %{"db" => 2_048, "media" => 3 * 1_048_576}
      assert report.media_parts == 3
      assert report.verified == true
      assert report.duration_s == 125
      assert report.components == ["db", "media"]

      email =
        ReportMail.build(%{email: "admin@example.com", notify_on_backup: :every_run}, report)

      assert email.text_body =~ "Size: db 2.0 KB, media 3.0 MB in 3 parts"
      assert email.text_body =~ "Took: 2 min 5 s"
      assert email.text_body =~ "Verified: yes"
      assert email.text_body =~ "set to every run"
      refute email.text_body =~ "kiln-db-x.dump"
    end

    test "a duration is never negative" do
      assert build(run(%{finished_at: DateTime.add(@at, -10, :second)})).duration_s == 0
    end

    test "destinations, with their file counts, permanence and first error line" do
      report =
        build(
          run(%{
            offsite_status: :partial,
            destinations: [
              dest(%{label: "Primary S3", status: :ok, files_ok: 2, files_total: 2}),
              dest(%{
                label: "Backup SFTP",
                kind: "sftp",
                status: :failed,
                files_ok: 1,
                files_total: 2,
                permanent: true,
                error: "the server refused\nsecond line"
              }),
              dest(%{label: "Later", status: %UnknownAtom{value: "parked"}})
            ]
          })
        )

      assert report.class == :partial

      assert [
               %{label: "Primary S3", status: "ok", files_ok: 2, files_total: 2, error: nil},
               %{
                 label: "Backup SFTP",
                 status: "failed",
                 permanent: true,
                 error: "the server refused"
               },
               %{label: "Later", status: "parked"}
             ] = report.destinations

      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)

      assert email.text_body =~
               "Backup SFTP: failed, 1 of 2 files (retrying won't fix this): the server refused"

      refute email.text_body =~ "second line"
      assert email.subject =~ "Backup partly off-site on Kiln Test"
    end

    test "never a destination's key" do
      report =
        build(
          run(%{
            destinations: [dest(%{key: "rclone:myremote:bucket", label: nil, kind: "rclone"})]
          })
        )

      assert [%{label: "An off-site destination (rclone)"}] = report.destinations
      refute inspect(report) =~ "myremote"
    end

    test "the schedules' cadence, a deleted schedule, or the trigger" do
      schedule = %{
        id: Ash.UUID.generate(),
        interval: :daily,
        time_of_day: ~T[03:00:00],
        time_zone: "Etc/UTC",
        starts_on: ~D[2026-01-01]
      }

      report = build(run(%{schedule_ids: [schedule.id]}), [schedule])
      assert report.schedules == ["Every day at 03:00 (Etc/UTC)"]
      assert Report.what(report) == "Every day at 03:00 (Etc/UTC)"

      assert build(run(%{schedule_ids: [Ash.UUID.generate()]})).schedules ==
               ["a schedule that no longer exists"]

      assert Report.what(build(run(%{trigger: "cron"}))) == "cron"
    end

    test "the first 5 error lines and 5 logged errors, capped, with the truncated note" do
      error = Enum.map_join(1..8, "\n", &"error line #{&1}")

      log =
        for n <- 1..7 do
          %LogEntry{
            at: @at,
            level: :error,
            step: "dump",
            message: "logged #{n} " <> String.duplicate("x", 400)
          }
        end ++ [%LogEntry{at: @at, level: :info, step: "dump", message: "an info line"}]

      report = build(run(%{status: :failed, error: error, log: log}))

      assert report.class == :failed
      assert length(report.errors) == 10
      assert Enum.take(report.errors, 5) == Enum.map(1..5, &"error line #{&1}")
      assert report.errors |> Enum.drop(5) |> Enum.all?(&(String.length(&1) == 300))
      refute Enum.any?(report.errors, &(&1 =~ "an info line"))
      assert report.truncated?

      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      assert email.text_body =~ "More lines are in the log."
      refute email.text_body =~ "error line 6"
    end

    test "few lines are not truncated" do
      report = build(run(%{status: :failed, error: "one line"}))
      assert report.errors == ["one line"]
      refute report.truncated?
    end

    test "links to the run's row and its log on the console" do
      run = run()
      report = Report.build(run, [], env: [], site_name: "Kiln Test")

      assert report.run_url =~ ~r{^https?://[^/]+/editor/backups\?run=#{run.id}$}
      assert report.log_url =~ ~r{^https?://[^/]+/editor/backups/log\?run=#{run.id}$}

      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      assert email.html_body =~ ~s|href="#{report.run_url}"|
      assert email.text_body =~ "Read its log: #{report.log_url}"
    end
  end

  describe "classes" do
    test "a succeeded run whose only destination entry is the unreadable one is a failure" do
      run =
        run(%{
          offsite_status: :failed,
          destinations: [
            dest(%{key: RunDestination.unreadable_key(), status: :failed, label: nil})
          ]
        })

      report = build(run)
      assert report.class == :failed
      assert [%{label: "The stored destinations (couldn't be read)"}] = report.destinations

      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      assert email.subject =~ "Backup failed on"
      assert email.text_body =~ "no off-site destination was reached"
    end

    test "partly off-site, skipped, canceled and still running" do
      partial =
        run(%{
          offsite_status: :partial,
          destinations: [dest(%{status: :ok}), dest(%{status: :failed})]
        })

      assert Report.classify(partial) == :partial
      assert Report.classify(run(%{status: :skipped})) == :skipped
      assert Report.classify(run(%{status: :canceled})) == :canceled
      assert Report.classify(run(%{status: :running})) == nil
    end

    test "recovered: a succeeded run that failed before" do
      assert Report.recovered?(run(%{last_failed_at: @at}))
      refute Report.recovered?(run())
      refute Report.recovered?(run(%{status: :failed, last_failed_at: @at}))

      report = build(run(%{last_failed_at: @at}))
      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      assert email.subject =~ "Backup recovered on Kiln Test"
      assert email.text_body =~ "which failed earlier, was resumed and has now succeeded"
    end
  end

  describe "an imported run that finished after all" do
    test "has its own wording, never \"resumed\"" do
      report = build(run(%{origin: :imported, trigger: "cron", last_failed_at: @at}))
      assert report.recovered?

      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      assert email.subject =~ "Backup finished after all on Kiln Test"
      assert email.text_body =~ "recorded as interrupted, finished after all"

      for text <- [email.subject, email.html_body, email.text_body] do
        refute text =~ "resumed"
        refute text =~ "recovered"
      end
    end
  end

  describe "the subject" do
    test "is one line, whatever the site name and the trigger hold" do
      report =
        build(run(%{status: :failed, trigger: "nightly\nBcc: evil@example.com"}), [],
          site_name: "Kiln\r\nX-Injected: yes"
        )

      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      refute email.subject =~ "\n"
      refute email.subject =~ "\r"

      assert email.subject =~
               "Backup failed on Kiln X-Injected: yes: nightly Bcc: evil@example.com"
    end
  end

  describe "no secrets, no control characters (redaction leak test)" do
    @db_password "current-db-password-77"
    @destination_secret "fake-secret-token-9z8y7x"
    @c1 <<0x9B::utf8>>
    @bidi <<0x202E::utf8>>

    @secrets [
      "postgres://kiln:hunter2secret@db/kiln",
      "secret_access_key=AKIAEXAMPLESECRET",
      "token=abc123def456",
      ":s3,access_key_id=X,secret_access_key=Y:bucket"
    ]

    # Every raw secret in a line, plus a C1 control and a bidi override.
    defp dirty(prefix),
      do:
        prefix <>
          " " <>
          Enum.join(@secrets, " ") <> " " <> @db_password <> " a" <> @c1 <> "b c" <> @bidi <> "d"

    # What the adapter boundary leaves of a destination's own secret
    # (`Destination.call/4`), which is not in key=value form in the text.
    defp destination_error do
      {:error, reason} =
        Destination.call(fake_config(%{"mode" => "fail"}, @destination_secret), :test, [])

      Destination.format_reason(reason) <> " " <> dirty("dest")
    end

    test "the HTML, text, subject and bell excerpt hold none of them" do
      run =
        run(%{
          status: :failed,
          trigger: dirty("trigger"),
          error: dirty("first"),
          log: [%LogEntry{at: @at, level: :error, step: "dump", message: dirty("logged")}],
          offsite_status: :failed,
          destinations: [
            dest(%{label: dirty("label"), status: :failed, error: destination_error()})
          ]
        })

      report = build(run, [], env: [{"PGPASSWORD", @db_password}], site_name: dirty("site"))
      email = ReportMail.build(%{email: "a@example.com", notify_on_backup: :failures}, report)
      excerpt = Report.excerpt(report)

      for text <- [
            email.subject,
            email.html_body,
            email.text_body,
            excerpt,
            inspect(Report.details(report))
          ] do
        for secret <- [
              "hunter2secret",
              "AKIAEXAMPLESECRET",
              "abc123def456",
              "access_key_id=X",
              "secret_access_key=Y",
              @db_password,
              @destination_secret
            ] do
          refute text =~ secret,
                 "#{inspect(secret)} leaked into #{inspect(String.slice(text, 0, 120))}"
        end

        refute text =~ @c1
        refute text =~ @bidi
      end

      assert email_text(email) =~ "***"
      assert excerpt =~ "***"
      assert email.text_body =~ "\u{FFFD}"
    end

    test "the database password known now is removed by default" do
      run = run(%{status: :failed, error: "connection failed"})
      env = KilnCMS.Backups.LogText.read_env()
      report = Report.build(run, [], site_name: "Kiln Test", org: nil)

      for {_var, secret} <- env, String.length(secret) >= 6 do
        refute inspect(report) =~ secret
      end

      assert report.errors == ["connection failed"]
    end
  end

  describe "the bell excerpt" do
    test "names the stamp, what it was for, and the first error line, in at most 200 characters" do
      report = build(run(%{status: :failed, error: "pg_dump exited 1\nmore"}))
      assert Report.excerpt(report) == "20261127-030000 (manual) pg_dump exited 1"

      long = build(run(%{status: :failed, error: String.duplicate("e", 500)}))
      assert String.length(Report.excerpt(long)) == 200
    end

    test "a partly off-site run says how many destinations were reached" do
      report =
        build(
          run(%{
            offsite_status: :partial,
            destinations: [dest(%{status: :ok}), dest(%{status: :failed})]
          })
        )

      assert Report.excerpt(report) ==
               "20261127-030000 (manual) reached 1 of 2 off-site destinations"

      assert Report.details(report) == %{
               "run_id" => report.run_id,
               "stamp" => "20261127-030000",
               "class" => "partial",
               "recovered" => false
             }
    end
  end
end
