#!/bin/bash
# Cobbler install trigger (installed in triggers/install/pre/ and triggers/install/post/).
# Cobbler calls it as:  <script> <objtype> <name> <ip>
# It only drops an event file; the real work happens in hpc-provision-dispatch,
# outside cobblerd, so a slow or failing step can never block Cobbler.
mode=$(basename "$(dirname "$0")")      # pre | post
[ "${1:-}" = "system" ] || exit 0
q=/var/lib/cobbler/hpc-queue
mkdir -p "$q"
f="$q/$2.$mode.$(date +%s%N)"
printf '%s %s %s\n' "$(date -Is)" "$mode" "${3:-}" > "$q/.tmp.$$" && mv "$q/.tmp.$$" "$f"
exit 0
