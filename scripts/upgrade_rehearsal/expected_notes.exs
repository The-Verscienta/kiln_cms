# The release headings `mix kiln.update` should print for an update, by the
# candidate's own `Mix.Tasks.Kiln.Update.upgrade_notes/3` (#1540).
#
#   elixir scripts/upgrade_rehearsal/expected_notes.exs \
#     KILN_UPDATE_EX CHANGELOG FROM_VERSION TO_VERSION
#
# Prints one version per line, oldest first — the same lines the task prints
# under "What this update asks of you". Pure string processing: it needs no
# deps and no compiled project.

[task_source, changelog, from, to] = System.argv()

Mix.start()
Code.require_file(task_source)

changelog
|> File.read!()
|> Mix.Tasks.Kiln.Update.upgrade_notes(Version.parse!(from), Version.parse!(to))
|> Enum.each(fn {version, _blocks} -> IO.puts(to_string(version)) end)
