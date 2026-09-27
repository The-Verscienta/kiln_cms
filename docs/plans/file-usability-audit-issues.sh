#!/usr/bin/env bash
# File usability audit GitHub issues for 2026-09-27.
# Requires: gh auth refresh -h github.com
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL_USABILITY="usability"
LABEL_A11Y="accessibility"
LABEL_AUDIT="audit-2026-09-usability"

ensure_labels() {
  gh label create "$LABEL_USABILITY" --description "Usability / UX" --color "1D76DB" 2>/dev/null || true
  gh label create "$LABEL_A11Y" --description "Accessibility" --color "5319E7" 2>/dev/null || true
  gh label create "$LABEL_AUDIT" --description "2026-09 usability audit" --color "BFDADC" 2>/dev/null || true
}

issue() {
  local title="$1" body="$2" labels="$3"
  gh issue create --title "$title" --body "$body" --label "$labels"
}

ensure_labels

TRACK=$(gh issue create --title "Tracking: 2026-09-27 usability & aesthetics audit" --body "$(cat <<'EOF'
Full-surface usability/aesthetics audit report: [`docs/audit-2026-09-27-usability.md`](../blob/main/docs/audit-2026-09-27-usability.md).

Child issues cover open backlog items; fixed findings get verification issues.
EOF
)" --label "$LABEL_USABILITY,$LABEL_AUDIT")

echo "Tracking: $TRACK"

# Fixed — verify
issue "[Audit] Verify: console page_title on site_* / backup / code_injection" "$(cat <<'EOF'
**Fixed in audit pass.** Eight LiveViews assigned `:page_title` but omitted `page_title=` on `Layouts.console`.

Verify sticky top bar shows the title on AI / storage / push / SSO / search / mail / code injection / backups.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Verify: editor chrome Save draft / Publish now / Visual demoted" "$(cat <<'EOF'
**Fixed.** Visual is `btn-default`; Save label is “Save draft”; Publish is “Publish now”. One primary remains Save.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Verify: calendar empty + task scope empty copy" "$(cat <<'EOF'
**Fixed.** Month/week with zero events shows the empty card; task empties distinguish All vs block/document scope.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Verify: form thank-you kit + embed Try again + public form labels" "$(cat <<'EOF'
**Fixed.** Thank-you/error load app.css; embed errors get Try again; public form fields use for/id + `.field-*`.
EOF
)" "$LABEL_USABILITY,$LABEL_A11Y,$LABEL_AUDIT"

issue "[Audit] Verify: account/membership header current_user + auth #main + search focus" "$(cat <<'EOF'
**Fixed.** Account/Membership pass `current_user`; auth has `<main id=\"main\">`; public search uses kit focus.
EOF
)" "$LABEL_USABILITY,$LABEL_A11Y,$LABEL_AUDIT"

issue "[Audit] Verify: TOTP re-enrol after recovery login" "$(cat <<'EOF'
**Fixed.** When `recovery_login?`, Settings shows “Set up a new authenticator” and enrolment UI while 2FA remains on.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

# Open backlog
issue "[Audit] Restyle /sign-in/verify onto Layouts.auth + ember tokens" "$(cat <<'EOF'
**High (open).** `two_factor_controller` renders a dark-only inline HTML island. Move to auth layout + light/dark kit.

See docs/audit-2026-09-27-usability.md #5.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Sweep interactive text-primary → text-primary-ink" "$(cat <<'EOF'
**High (open).** Ember `#FF6200` ≈3:1 as text; kit provides \`text-primary-ink\`. Sweep overview, chips, delivery links.

See docs/audit-2026-09-27-usability.md #11.
EOF
)" "$LABEL_USABILITY,$LABEL_A11Y,$LABEL_AUDIT"

issue "[Audit] Normalize list empty states to <.empty_state>" "$(cat <<'EOF'
**Medium.** Trash, taxonomy, inbox, search palette, media trash still use muted \`<p>\` empties. Content/Media are the reference.

See audit #18.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Content editor chrome density + kit pass" "$(cat <<'EOF'
**Medium.** Header action strip, inspector \`.tabs\`, hover-only block chrome, device preview gap vs design-language.

See audit #19 / WS2.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Settings long-scroll TOC + Form Builder kit + crumbs" "$(cat <<'EOF'
**Medium.** Your settings / Mail need section TOC; Form Builder ignore \`.tabs\`/\`<.input>\`; Team/Webhooks/Mail “← All content” crumbs.

See audit #20.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] AuthOverrides kit + setup brand + passkey CTA" "$(cat <<'EOF'
**Medium.** Auth forms bespoke utilities; setup unbranded; passkey CTA JS-injected.

See audit #21.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

issue "[Audit] Delivery: preview public-* hooks + header a11y + mobile nav" "$(cat <<'EOF'
**Medium.** Preview/in-context omit public-article hooks; header nav aria-label; locale-aware error links; mobile header wrap.

See audit #22.
EOF
)" "$LABEL_USABILITY,$LABEL_A11Y,$LABEL_AUDIT"

issue "[Audit] Form submit: re-render with field errors instead of replace" "$(cat <<'EOF'
**Medium.** Validation still replaces the form with a message page (recovery improved). Prefer inline field errors.

See audit #23.
EOF
)" "$LABEL_USABILITY,$LABEL_AUDIT"

echo "Done. Tracking issue: $TRACK"
