defmodule KilnCMS.Backups.RcloneRemoteTest do
  @moduledoc """
  `KilnCMS.Backups.RcloneRemote.split_credentials/1` (#2690), and the same
  cases through `scripts/backup.sh`'s `rclone_split_remote`, which must agree.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.RcloneRemote

  @script Path.expand("../../../scripts/backup.sh", __DIR__)

  @cases [
    # Nothing to move.
    {"r2:kiln-backups", "r2:kiln-backups", []},
    {"r2:", "r2:", []},
    {":s3:bucket", ":s3:bucket", []},
    {"/var/backups/offsite", "/var/backups/offsite", []},
    {"relative/dir", "relative/dir", []},
    # An inline backend becomes `kiln_offsite`.
    {":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket/kiln",
     "kiln_offsite:bucket/kiln",
     [
       {"RCLONE_CONFIG_KILN_OFFSITE_TYPE", "s3"},
       {"RCLONE_CONFIG_KILN_OFFSITE_ACCESS_KEY_ID", "AKIAEXAMPLE1"},
       {"RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY", "SUPERSECRETVAL"}
     ]},
    # Quoted values keep `,` and `:`; a doubled quote is one quote; a bare key
    # is `true`; `-` in a key is `_` in the variable.
    {~S{:s3,endpoint="https://acct.r2.example:443",secret-access-key='it''s,a:secret',env_auth:b},
     "kiln_offsite:b",
     [
       {"RCLONE_CONFIG_KILN_OFFSITE_TYPE", "s3"},
       {"RCLONE_CONFIG_KILN_OFFSITE_ENDPOINT", "https://acct.r2.example:443"},
       {"RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY", "it's,a:secret"},
       {"RCLONE_CONFIG_KILN_OFFSITE_ENV_AUTH", "true"}
     ]},
    # A named remote with overrides keeps its name.
    {"r2,secret_access_key=SUPERSECRETVAL:kiln", "r2:kiln",
     [{"RCLONE_CONFIG_R2_SECRET_ACCESS_KEY", "SUPERSECRETVAL"}]},
    {"My_R2,token=abcdefgh:", "My_R2:", [{"RCLONE_CONFIG_MY_R2_TOKEN", "abcdefgh"}]},
    # A name no variable can carry, or a string rclone would not parse either:
    # left alone (rclone's error goes through Redact).
    {"my-r2,secret_access_key=x:b", "my-r2,secret_access_key=x:b", []},
    {":s3,secret_access_key=x", ":s3,secret_access_key=x", []},
    {":s3,secret_access_key='unterminated:b", ":s3,secret_access_key='unterminated:b", []},
    {":s3,key='quoted'junk:b", ":s3,key='quoted'junk:b", []},
    {":s3,:b", ":s3,:b", []}
  ]

  test "translates a connection string into a named remote plus RCLONE_CONFIG_* variables" do
    for {input, remote, env} <- @cases do
      assert RcloneRemote.split_credentials(input) == {remote, env}, "for #{input}"
    end
  end

  test "no translated remote keeps a parameter's value in the argument" do
    for {input, remote, env} <- @cases, env != [] do
      for {_var, value} <- env, value not in ["s3", "true"] do
        refute remote =~ value, "#{input} left #{value} in #{remote}"
      end
    end
  end

  @tag :tmp_dir
  test "scripts/backup.sh's rclone_split_remote agrees on every case", %{tmp_dir: tmp} do
    bash = System.find_executable("bash") || flunk("needs bash")

    # The function alone: sourcing the script would run it.
    function =
      @script
      |> File.read!()
      |> then(&Regex.run(~r/^rclone_split_remote\(\) \{\n.*?^\}\n/ms, &1))
      |> hd()

    lib = Path.join(tmp, "split.sh")
    File.write!(lib, function)

    for {input, remote, env} <- @cases do
      script = ~S"""
      set -euo pipefail
      . "$1"
      rclone_split_remote "$2"
      printf '%s\n' "$OFFSITE_REMOTE"
      if [ "${#OFFSITE_ENV[@]}" -gt 0 ]; then printf '%s\n' "${OFFSITE_ENV[@]}"; fi
      """

      assert {out, 0} = System.cmd(bash, ["-c", script, "split", lib, input])

      expected =
        Enum.map_join([remote | Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)], &(&1 <> "\n"))

      assert out == expected, "for #{input}"
    end
  end
end
