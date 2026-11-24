# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="condition-text-ops"></a>

- **Conditional fields can match text (#3270).** A **Show when** or **Required when** test in `/editor/fields` now offers **contains**, **does not contain**, **starts with** and **ends with** when it reads a text, URL or choice field: "show **Download notes** when **File URL** ends with `.pdf`". In a rule these are the operators `contains`, `not_contains`, `starts_with` and `ends_with`, each with a non-blank string `value`.
  - **Matching ignores case and surrounding spaces.** Both sides are trimmed, as for `eq`, and lowercased. The editor's evaluator and the server agree on non-ASCII text too (a Greek word-final sigma folds to ς on both); one shared fixture holds them to it.
  - **Lists and non-text values.** On a multiple field a test holds when any item matches, so **does not contain** holds only when no item contains the text. An empty value contains nothing. A number, yes/no or date field cannot use these tests: the definition is refused, and so is retyping a field to a non-text type while a text test reads it.
  - **Additive.** No migration. An older release reading a rule with one of these operators treats it as a rule it cannot read: the field is shown and not required, and the definition cannot be saved until the rule is changed.

## Fixed

<a id="external-command-group-kill"></a>

- **External programs are stopped by a process-group kill from inside, never by a pid from the VM (#2624).** `KilnCMS.ExternalCommand` runs qpdf, ffmpeg/ffprobe, `pg_dump`, `pg_restore`, `tar` and `rclone`. It used to stop a program on a deadline, a canceled or fenced backup step, or its caller's death by sending a kill to the program's OS pid from the VM. By the time that kill was sent the program could already have exited and been reaped, and its pid reused by an unrelated process. The program now runs under a fixed `/bin/sh` wrapper whose stdin watcher, when the port closes, sends SIGKILL to its own process group: the wrapper, the program, anything the program started, and the watcher. A process group's id can't be reused while any member is alive, so the kill can't reach a stranger, and it needs no binary on `PATH`.
  - **More is stopped.** A stopped program's own children (an ffmpeg helper, a `tar` filter) stop too, and the program stops when the VM exits, since the port's pipe closes with it.
  - **What a caller can see.** The program's stdin is `/dev/null`. A missing program returns exit status 127 and a non-executable one 126, instead of raising. The program must be given as an absolute path (every caller already passes a `System.find_executable/1` result); anything else raises `ArgumentError`. The deadline kill finishes just after `run/4` returns `:timeout`, not before.
  - **Orphans.** The killed processes are reparented to PID 1, which must reap them. The release image's `/bin/sh` command does, and so does the VM when it is PID 1. A custom entrypoint that leaves some other program as PID 1 should use an init such as `tini` (`docker run --init`).
