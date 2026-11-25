#!/bin/sh
# Tests of the xml-parse command line: tests/cli.sh PATH-TO-XML-PARSE (run by `zig build test`).
bin=$1
[ -x "$bin" ] || { echo "usage: cli.sh XML-PARSE" >&2; exit 2; }
dir=$(mktemp -d) || exit 1
trap 'rm -rf "$dir"' EXIT
failed=0

printf '<a x="1">hi<b/></a>' >"$dir/ok.xml"
printf '<a>\n<b></a>' >"$dir/bad.xml"

# expect NAME STATUS STDOUT STDERR-PATTERN ARGS...   (an empty pattern means: stderr is empty)
expect() {
    name=$1 status=$2 stdout=$3 pattern=$4
    shift 4
    "$bin" "$@" >"$dir/out" 2>"$dir/err"
    got=$?
    problem=
    [ "$got" = "$status" ] || problem="exit status $got, wanted $status"
    [ "$(cat "$dir/out")" = "$stdout" ] || problem="$problem; stdout was: $(cat "$dir/out")"
    if [ -z "$pattern" ]; then
        [ -s "$dir/err" ] && problem="$problem; unexpected stderr: $(cat "$dir/err")"
    else
        grep -q -- "$pattern" "$dir/err" || problem="$problem; stderr lacks '$pattern': $(cat "$dir/err")"
    fi
    if [ -n "$problem" ]; then
        echo "FAIL: $name: $problem" >&2
        failed=1
    fi
}

usage='usage: xml-parse check FILE... | events FILE | text FILE'

expect "check a good file" 0 "" "" check "$dir/ok.xml"
expect "check reports the position" 1 "$dir/bad.xml:2:6: an end tag does not match its start tag: MismatchedTag" "" check "$dir/bad.xml"
expect "check goes on after a bad file" 1 "$dir/bad.xml:2:6: an end tag does not match its start tag: MismatchedTag" "" check "$dir/bad.xml" "$dir/ok.xml"
expect "a missing file has no position" 1 "$dir/none.xml: FileNotFound" "" check "$dir/none.xml"
expect "text" 0 "hi" "" text "$dir/ok.xml"
expect "events" 0 "start a (1 attributes)
text 2 bytes
start b (0 attributes)
end b
end a" "" events "$dir/ok.xml"
expect "events of a missing file" 1 "" "none.xml: FileNotFound" events "$dir/none.xml"
expect "no command" 2 "" "$usage"
expect "unknown command" 2 "" "$usage" frobnicate "$dir/ok.xml"
expect "check without a file" 2 "" "$usage" check
expect "text without a file" 2 "" "$usage" text
expect "text with too many files" 2 "" "$usage" text "$dir/ok.xml" "$dir/ok.xml"
expect "events with too many files" 2 "" "$usage" events "$dir/ok.xml" extra
expect "help" 0 "$usage" "" --help
expect "short help" 0 "$usage" "" -h

# Output that cannot be written is a failure, for short output (still buffered) and long.
if [ -w /dev/full ]; then
    { printf '<a>'; head -c 100000 /dev/zero | tr '\0' x; printf '</a>'; } >"$dir/long.xml"
    for args in "text $dir/ok.xml" "events $dir/ok.xml" "text $dir/long.xml" "check $dir/bad.xml" "--help"; do
        # shellcheck disable=SC2086
        if "$bin" $args >/dev/full 2>"$dir/err"; then
            echo "FAIL: '$args' succeeded although its output could not be written" >&2
            failed=1
        elif ! grep -q WriteFailed "$dir/err"; then
            echo "FAIL: '$args' did not say that writing failed: $(cat "$dir/err")" >&2
            failed=1
        fi
    done
fi

exit $failed
