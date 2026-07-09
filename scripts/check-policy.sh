#!/bin/sh -e
# Verify a freshly built ImageMagick binary actually loaded the security policy
# we expect -- the `secure` profile, widened to allow 48 MP photos.
#
# It reads the output of ImageMagick's own `identify -list policy` (or
# `magick -list policy`) on STDIN, so the same check works everywhere:
#   - laptop:  the Makefile `check` target pipes the podman-run binary in
#   - EC2:     build-on-ec2.sh pipes the native binary in
#
# Why this matters: if policy.xml is missing or not found at runtime,
# ImageMagick does not error -- it just runs with NO restrictions. This turns
# that silent failure into a loud build failure.

# Strip any CR that a tty-allocated `podman run -t` may have added, so string
# comparisons below are exact.
INPUT=$(tr -d '\r')

fail() { echo "check-policy: FAIL -- $1" >&2; exit 1; }

# 1. The on-disk policy.xml must actually be loaded (not just the built-in
#    default). Its path shows up in the listing when it is found.
echo "$INPUT" | grep -q 'policy.xml' \
    || fail "no policy.xml path in -list policy output (policy not loaded)"

# 2. The four resource limits we widen for 48 MP photos must carry our values.
#    -list policy prints each limit as a 'name:' line followed by a 'value:'
#    line; pair them with awk and take the effective (last) value.
check_resource() {
    name="$1"; want="$2"
    got=$(echo "$INPUT" | awk -v n="$name" '
        /name:/  { cur = $2 }
        /value:/ { if (cur == n) v = $2 }
        END      { print v }')
    [ "$got" = "$want" ] || fail "resource $name = '${got:-<none>}', expected '$want'"
}
check_resource width  16KP
check_resource height 16KP
check_resource area   256MP
check_resource memory 1GiB

# 3. The `secure` hardening must be present: at least one coder/delegate is
#    denied. The permissive/open policy denies nothing, so this proves we did
#    not accidentally ship an unhardened layer.
echo "$INPUT" | grep -qi 'rights: *None' \
    || fail "no denied coder/delegate found (secure hardening missing)"

echo "check-policy: OK -- hardened secure policy with 48 MP limits is active"
