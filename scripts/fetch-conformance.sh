#!/bin/sh
# Downloads the W3C XML Conformance Test Suite (xmlts20130923) into DIR (default
# ./conformance-suite, ignored by git) so `zig build conformance -Dsuite=DIR/xmlconf` can run it.
# The suite has its own licence (https://www.w3.org/XML/Test/) and is not part of this repository.
set -e
dir="${1:-conformance-suite}"
mkdir -p "$dir"
curl -fsSL -o "$dir/xmlts.tar.gz" https://www.w3.org/XML/Test/xmlts20130923.tar.gz
tar xzf "$dir/xmlts.tar.gz" -C "$dir"
echo "unpacked to $dir/xmlconf"
