# NAME

xml-parse - check an XML file, list its events, or extract its text

# SYNOPSIS

    xml-parse check FILE...

    xml-parse events FILE

    xml-parse text FILE

    xml-parse --help | -h

# DESCRIPTION

A small command line over the xml-zig library. It reads each file as a stream, so the size of a file does not matter for memory. Built with `zig build cli` as `zig-out/bin/xml-parse`.

# COMMANDS

check

Reads each FILE and prints `FILE:LINE:COLUMN: message: Error` for the ones that are not well-formed (just `FILE: Error` for one that cannot be opened). Exit status is 1 if any is not.

events

Prints one line per event: `start NAME (N attributes)`, `end NAME`, the kind of every other event.

text

Writes the character data (text and CDATA) of FILE to standard output.

# EXIT STATUS

0 on success; 1 if a file is not well-formed or cannot be read, or the output cannot be written; 2 for a usage error, including `check` with no files and extra arguments to `events` or `text`.

# SEE ALSO

xml-zig(3)

