#!/bin/sh -e
# Raise the resource ceilings in the `secure` ImageMagick policy so the
# layer can process full-resolution (48 MP) iPhone photos.
#
# The build configures ImageMagick with --with-security-policy=secure,
# which installs a policy.xml that disables the dangerous coders/delegates
# (SVG, MSL, MVG, URL, ...) AND clamps resources hard: width/height/area
# default to 8KP, which REJECTS a 48 MP iPhone photo (8064 x 6048).
#
# The coder/delegate lockdown stays; this only widens the DIMENSION limits
# (width/height/area), which gate on pixel count. The `memory` limit is left at
# the secure default: this is a Q8, non-HDRI build, so a 48 MP image decodes to
# only ~186 MiB -- well under the default. See the README "Security policy" and
# "Precision" sections for the reasoning.
#
# Usage: scripts/secure-policy-allow-48mp.sh path/to/result
#   (defaults to ./result if no argument is given)

RESULT_DIR="${1:-result}"
POLICY="$RESULT_DIR/etc/ImageMagick-7/policy.xml"

if [ ! -f "$POLICY" ]; then
    echo "secure-policy-allow-48mp: policy.xml not found at $POLICY" >&2
    echo "  (did the build run with --with-security-policy=secure?)" >&2
    exit 1
fi

# Rewrite by name attribute so we do not depend on the value ImageMagick
# shipped. Portable: no GNU-only `sed -i`; write to a temp file and move.
TMP=$(mktemp)
sed \
    -e 's|\(name="width" value="\)[^"]*"|\116KP"|' \
    -e 's|\(name="height" value="\)[^"]*"|\116KP"|' \
    -e 's|\(name="area" value="\)[^"]*"|\1256MP"|' \
    "$POLICY" >"$TMP"
mv "$TMP" "$POLICY"

echo "secure-policy-allow-48mp: widened dimension limits in $POLICY"
grep -E 'name="(width|height|area)"' "$POLICY" | sed 's/^[[:space:]]*/  /'
