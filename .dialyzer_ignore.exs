# Dialyzer warnings to ignore. Keep this list tight — only third-party /
# version-specific noise, never bugs in our own logic.
[
  # Gettext's generated backend calls Gettext.Plural.plural/2 with Expo's
  # opaque %Expo.PluralForms{} (from the fr/es Plural-Forms headers, exercised
  # once a locale has plural msgids). OTP 29's stricter opacity checking flags
  # the generated code — same false-positive family as the importer fix in
  # PR #257. Third-party generated code only.
  {"lib/kiln_cms_web/gettext.ex", :call_without_opaque}
]
