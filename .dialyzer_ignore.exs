# Dialyzer warnings to ignore. Keep this list tight — only third-party /
# version-specific noise, never bugs in our own logic.
[
  # The regex catches `Ash.Resource.record/0` references in ash_authentication_phoenix
  # (and similar) typespecs. Dialyzer can't resolve it on some OTP/Elixir combos
  # (e.g. OTP 29 / 1.20). Third-party noise only; keep the list tight.
  ~r/Unknown type: Ash\.Resource\.record/,
  # Gettext's generated backend calls Gettext.Plural.plural/2 with Expo's
  # opaque %Expo.PluralForms{} (from the fr/es Plural-Forms headers, exercised
  # once a locale has plural msgids). OTP 29's stricter opacity checking flags
  # the generated code — same false-positive family as the importer fix in
  # PR #257. Third-party generated code only.
  {"lib/kiln_cms_web/gettext.ex", :call_without_opaque}
]
