#!/bin/sh
# Downloads the W3C XML Conformance Test Suite (xmlts20130923) into DIR (default
# ./conformance-suite, ignored by git) so `zig build conformance -Dsuite=DIR/xmlconf` can run it.
# The suite has its own licence (https://www.w3.org/XML/Test/) and is not part of this repository.
# Nothing is unpacked unless the archive is the one the published results were measured with.
set -e
url=https://www.w3.org/XML/Test/xmlts20130923.tar.gz
# SHA-256 of the archive as downloaded from that URL on 2026-11-24. W3C publishes no checksum
# that this was checked against: it pins the content, it does not vouch for it.
want=9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f
dir="${1:-conformance-suite}"
mkdir -p "$dir"
archive="$dir/xmlts.tar.gz"
curl -fsSL -o "$archive" "$url"
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum <"$archive")
else
    got=$(shasum -a 256 <"$archive")
fi
got=${got%% *}
if [ "$got" != "$want" ]; then
    echo "$archive: SHA-256 is $got, expected $want; not unpacked" >&2
    exit 1
fi
tar xzf "$archive" -C "$dir"
echo "unpacked to $dir/xmlconf"
