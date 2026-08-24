#!/bin/bash
#
# normalize-xcstrings.sh
# Safe normalizer for String Catalogs (.xcstrings) to keep git diffs small
# and stable. One catalog per invocation.
#
# Why this exists:
#   Xcode rewrites the whole .xcstrings file (different key order, formatting,
#   version bumps) every time you add/edit keys or translations in the UI.
#   Without normalization this creates huge "reorder" diffs even for tiny changes.
#
# Catalogs (never implied — pick exactly one):
#   Localizable.xcstrings   UI / intent titles / descriptions (README Localizations)
#                           (default when you pass no argument)
#   AppShortcuts.xcstrings  Apple-required Siri utterance table
#                           (Play / Start / Pause / Stop ${applicationName}
#                           and the ${language} variants). Siri trains from
#                           this table only — do not merge those phrases into
#                           Localizable. Must be requested explicitly so a
#                           Localizable restabilize never surprises the Siri
#                           catalog with a reorder diff.
#   InfoPlist.xcstrings     Widget extension CFBundleDisplayName (gallery
#                           section). The OS reads InfoPlist.strings, not
#                           Localizable. Pass the path explicitly.
#
# What a successful run does:
#   - Forces alphabetical order on all string *keys* (top level).
#   - Forces alphabetical order on language codes inside every "localizations".
#   - Canonicalizes key ordering inside entries and at the top level for stability.
#   - Produces a deterministic pretty-printed form (with Xcode-style "key" : value spacing)
#     so that running the script again on its own output produces no diff.
#   - Validates that we did not lose any keys.
#
# IMPORTANT:
#   The *first* time you run this after a big Xcode edit (or the compliance pass),
#   the diff vs the previous committed version will be large. This is expected —
#   it is the one-time cost of moving the entire catalog to a stable sorted baseline.
#   After you commit the normalized version, *future* runs will produce small,
#   meaningful diffs.
#
# Usage (from repo root):
#   ./Scripts/normalize-xcstrings.sh
#   ./Scripts/normalize-xcstrings.sh --localizable
#   ./Scripts/normalize-xcstrings.sh --app-shortcuts
#   ./Scripts/normalize-xcstrings.sh "Lutheran Radio/AppShortcuts.xcstrings"
#   ./Scripts/normalize-xcstrings.sh LutheranRadioWidget/InfoPlist.xcstrings
#
# AGENT NOTE: AppShortcuts is opt-in on purpose. A default (or --localizable)
# run must not touch AppShortcuts.xcstrings. There is no --all: run twice if
# both catalogs need a restabilize. See README.md Localizations and
# RadioPlaybackIntents.swift (Siri phrases are not Localizable).
#
# Safety:
#   - Creates a .bak before touching anything.
#   - Aborts and restores from backup if the key count changes.
#   - Uses temp files for all conversions.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "${BASH_SOURCE[0]}")")"
LOCALIZABLE_PATH="$REPO_ROOT/Lutheran Radio/Localizable.xcstrings"
APPSHORTCUTS_PATH="$REPO_ROOT/Lutheran Radio/AppShortcuts.xcstrings"

print_usage() {
    cat <<EOF
Usage: $0 [catalog]

Normalizes exactly one String Catalog per invocation so git diffs stay
small. AppShortcuts.xcstrings is never implied — request it explicitly.

Catalog:
  (no args), --localizable, localizable
      Lutheran Radio/Localizable.xcstrings
      (UI strings, intent titles / descriptions)

  --app-shortcuts, --appshortcuts, app-shortcuts, appshortcuts
      Lutheran Radio/AppShortcuts.xcstrings
      (Siri utterance table; Apple trains from this file only)

  <path-to.xcstrings>
      that file only (relative paths are from the repo root)
      (e.g. LutheranRadioWidget/InfoPlist.xcstrings)

  -h, --help
      this message

There is no --all. To restabilize both catalogs:

  ./Scripts/normalize-xcstrings.sh
  ./Scripts/normalize-xcstrings.sh --app-shortcuts
EOF
}

# Resolve the single catalog this invocation will touch into XCSTRINGS_PATH.
# Must not run inside $() — --help / --all `exit` would only kill that subshell
# and the usage text would be treated as a file path.
# - Parameters: all CLI args ($@). Zero or one catalog selector.
# - Exits: 0 on --help; 1 on unknown flags, --all, or extra args.
resolve_catalog() {
    if [[ $# -gt 1 ]]; then
        echo "Error: one catalog per invocation (got $# arguments)." >&2
        echo "Run again with --app-shortcuts if you also need the Siri table." >&2
        print_usage >&2
        exit 1
    fi

    local arg="${1:-}"
    case "$arg" in
        ""|--localizable|localizable|-l)
            XCSTRINGS_PATH="$LOCALIZABLE_PATH"
            ;;
        --app-shortcuts|--appshortcuts|app-shortcuts|appshortcuts)
            XCSTRINGS_PATH="$APPSHORTCUTS_PATH"
            ;;
        -h|--help|help)
            print_usage
            exit 0
            ;;
        --all)
            echo "Error: refusing --all. This script never normalizes both catalogs in one run." >&2
            echo "Request AppShortcuts separately: $0 --app-shortcuts" >&2
            exit 1
            ;;
        -*)
            echo "Error: unknown option: $arg" >&2
            print_usage >&2
            exit 1
            ;;
        *)
            if [[ "$arg" == /* ]]; then
                XCSTRINGS_PATH="$arg"
            else
                XCSTRINGS_PATH="$REPO_ROOT/$arg"
            fi
            ;;
    esac
}

XCSTRINGS_PATH=""
resolve_catalog "$@"

if [[ ! -f "$XCSTRINGS_PATH" ]]; then
    echo "Error: File not found: $XCSTRINGS_PATH" >&2
    exit 1
fi

REL_PATH="${XCSTRINGS_PATH#"$REPO_ROOT/"}"
BACKUP="$XCSTRINGS_PATH.bak"
TMP_FINAL=$(mktemp)

cleanup() {
    rm -f "$TMP_FINAL"
}
trap cleanup EXIT

CATALOG_BASENAME="$(basename "$XCSTRINGS_PATH")"

echo "=== Normalizing String Catalog ==="
echo "File: $REL_PATH"
case "$CATALOG_BASENAME" in
    AppShortcuts.xcstrings)
        echo "Catalog: AppShortcuts (Siri utterances — requested explicitly)"
        ;;
    Localizable.xcstrings)
        echo "Catalog: Localizable (UI / intent chrome)"
        ;;
esac

# 1. Make a safety backup
cp -p "$XCSTRINGS_PATH" "$BACKUP"
echo "Backup saved to $BACKUP"

# 2. Count keys before
BEFORE_COUNT=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(data.get("strings", {})))
' "$XCSTRINGS_PATH")
echo "Keys before normalization: $BEFORE_COUNT"

# 3. Sort + canonicalize directly from the .xcstrings (valid JSON).
#    We intentionally do *not* round-trip through `plutil -convert json` for the
#    data. plutil's JSON writer can reorder keys and alter whitespace in ways
#    that make repeated runs non-idempotent. Direct Python load + controlled
#    write gives us byte-stable output on re-run.
python3 - "$XCSTRINGS_PATH" "$TMP_FINAL" <<'PYEOF'
import json
import sys
import re
from pathlib import Path

in_path  = Path(sys.argv[1])
out_path = Path(sys.argv[2])

data = json.loads(in_path.read_text(encoding="utf-8"))

strings = data.get("strings", {})

# Sort the top-level keys (the localization identifiers) alphabetically,
# using case-insensitive (casefold) ordering so the result "looks alphabetical"
# to humans (e.g. "accessibility..." before "Configuration...").
sorted_strings = {k: strings[k] for k in sorted(strings.keys(), key=str.casefold)}

# (Languages inside localizations stay on plain sorted() — they are always
# lowercase ISO codes and conventional order is already what we want.)

# Inside each entry:
#   - sort the language codes alphabetically
#   - canonicalize sibling key order so that Xcode's occasional reordering of
#     "comment", "extractionState", "isCommentAutoGenerated" etc. relative to
#     the big "localizations" dict does not create future noise.
#
# Chosen layout (after "comment" if present):
#   localizations (the actual translations — the primary payload)
#   then annotation keys (extractionState, isCommentAutoGenerated, ...)
# This is the stable canonical form the normalizer will enforce.
PREFERRED_ENTRY_KEYS = ["comment", "localizations", "extractionState", "isCommentAutoGenerated"]

for key, entry in list(sorted_strings.items()):
    locs = entry.get("localizations")
    if isinstance(locs, dict) and locs:
        entry["localizations"] = {lang: locs[lang] for lang in sorted(locs.keys())}

    # Rebuild entry with preferred keys first, then any remaining keys in alpha order
    new_entry = {}
    for k in PREFERRED_ENTRY_KEYS:
        if k in entry:
            new_entry[k] = entry[k]
    for k in sorted((k for k in entry.keys() if k not in new_entry), key=str.casefold):
        new_entry[k] = entry[k]
    sorted_strings[key] = new_entry

# Rebuild the whole document with a stable top-level key order.
# This prevents "sourceLanguage" / "strings" / "version" from jumping around.
new_data = {}
for k in ("sourceLanguage", "strings", "version"):
    if k == "strings":
        new_data[k] = sorted_strings
    elif k in data:
        new_data[k] = data[k]
# Preserve any other future top-level keys (sorted after the known ones)
for k in sorted(data.keys()):
    if k not in new_data:
        new_data[k] = data[k]

raw = json.dumps(new_data, indent=2, ensure_ascii=False, sort_keys=False).rstrip()

# Force the same whitespace style the committed baseline and Xcode use:
# "key" : value   (space before the colon)
raw = re.sub(r'("(?:(?:[^"\\]|\\.)*)")\s*:', r'\1 :', raw)

out_path.write_text(raw, encoding="utf-8")
PYEOF

echo "Python sort complete."

# 5. Verify key count did not change (critical safety check)
#    (We no longer run a final plutil -convert json on the result; that step
#    was turning the file into a single minified line and reordering top keys.)
AFTER_COUNT=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(data.get("strings", {})))
' "$TMP_FINAL")

echo "Keys after normalization: $AFTER_COUNT"

if [[ "$AFTER_COUNT" != "$BEFORE_COUNT" ]]; then
    echo "ERROR: Key count changed ($BEFORE_COUNT -> $AFTER_COUNT). Aborting and restoring backup." >&2
    cp -p "$BACKUP" "$XCSTRINGS_PATH"
    rm -f "$BACKUP"   # optional: keep the .bak for manual inspection if you want
    exit 1
fi

# 7. Install the normalized file
cp -p "$TMP_FINAL" "$XCSTRINGS_PATH"

echo "Normalization successful. File replaced with sorted version."
echo ""
echo "Next steps:"
echo "  git diff --stat \"$REL_PATH\""
echo "  git diff -- \"$REL_PATH\" | head -30"
echo ""
echo "If this is the first normalization, the diff will be large (full reorder)."
echo "That is normal. Commit it as the new baseline."
# Remind only after a Localizable run. An explicit AppShortcuts path (or
# --app-shortcuts) already targeted the Siri table; do not claim otherwise.
if [[ "$CATALOG_BASENAME" == "Localizable.xcstrings" ]]; then
    echo ""
    echo "AppShortcuts.xcstrings was not touched. To normalize the Siri table:"
    echo "  $0 --app-shortcuts"
fi
echo ""
echo "You can safely delete the backup when you are happy:"
echo "  rm \"$BACKUP\""
