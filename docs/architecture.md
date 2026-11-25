# Architecture

How xml-zig is put together today. Why it is this way: `decisions/`. What it must do: `../ai/SPEC.md`.

## Modules

```
                  +-------------+      +-------------+
                  | chars.zig   |      | doctype.zig |   syntax shared by both directions
                  +------+------+      +------+------+
                         |                    |
          +--------------+---------+----------+
          |                        |
   +------v------+          +------v------+
   | reader.zig  |          | writer.zig  |
   | pull parser |          | serializer  |
   +------+------+          +------+------+
          |                        |
          +-----------+------------+
                      |
               +------v------+
               |  dom.zig    |   Document = reader -> tree -> writer
               +-------------+
```

`root.zig` re-exports the public names. Nothing touches files or the operating system: input is a `*std.Io.Reader`, output a `*std.Io.Writer`.

| File | Holds |
|---|---|
| `chars.zig` | XML `Char` and `Name` classes, UTF-8 checking, QName and namespace-declaration rules |
| `doctype.zig` | The syntax of the DOCTYPE declaration (production 28); the internal subset is only skimmed for its end |
| `reader.zig` | Byte access and decoding, the parser, namespace scopes, limits, diagnostics |
| `writer.zig` | Escaping, element and namespace stacks, prolog order, indentation |
| `dom.zig` | `Document`, `Element`, `Node`; lookups; writing a tree back |

## Reader

Bytes pass through three layers:

```
source -> peekRaw/tossRaw -> peekByte/tossByte -> takeByte -> parser
          input limit,        UTF-16 and            line ends, position,
          pushed-back and     ISO-8859-1 to UTF-8    UTF-8 and Char checks
          unbuffered input
```

- Every input byte goes through `tossRaw` exactly once, so `max_input_bytes` counts source bytes whatever the encoding.
- Every parsed byte, except a byte order mark, goes through `takeByte`, so characters are checked once, where they are. The one other source of text, caller-supplied entity values, is checked where it is inserted.
- These four functions run per byte and are marked `inline`. The rare paths are kept out of them (`peekRawSlow` is `noinline`). When one stopped being inlined, parsing took more than twice as long: measure after touching them.
- Errors default to the position of the byte last taken (`fail`); `failHere` is for the end of input and bytes not yet taken. Faults found after a whole tag, XML declaration or DOCTYPE has been read use a remembered `Mark`.

### State and memory

The parser does not recurse. It keeps `State` (start, prolog, content, epilog, done) and a few lists that are reused from event to event:

| List | Holds | Bounded by |
|---|---|---|
| `buf` | the current text, comment, CDATA, PI, DOCTYPE or declaration | `max_token_bytes` |
| `tag_buf`, `raw_attrs`, `attrs` | the current start tag | `max_tag_bytes`, `max_attributes` |
| `names`, `name_lens` | names of the open elements | `max_depth` x `max_name_bytes` |
| `ns_bytes`, `ns_binds`, `ns_marks` | namespace declarations in scope | `max_namespace_bytes`, `max_namespace_bindings` |
| `ref_buf`, `last_name` | a reference's name; the name of the element that ended | `max_name_bytes` (+ one URI) |

Prefix lookup is a backwards scan of the bindings in scope; `max_namespace_bindings` is what keeps it cheap.

Event data borrows from these lists until the next call. After any error the reader is failed and returns that error from then on, because the lists may be half-updated.

## Tree

`Document.parseReader` drives a `Reader` with an explicit stack of open elements. Finished data is copied into one arena, owned by the `Document`; the lists used while building belong to the caller's allocator and are freed before returning. A text run is gathered in one scratch buffer and copied once, when the next node or tag ends it. Allocate everything from the arena **before** copying the arena into the result.

`Document.write` and `Element.appendText` walk the tree with explicit stacks, so depth is limited by memory, not by the call stack.

## Writer

The writer streams: it holds the open start tag's attribute names, and for each open element its name, namespace declarations and layout state. Checks happen before anything is written, so a refused call leaves the output unchanged. Namespace prefixes can only be judged when a start tag is complete (`checkTag`), which happens while the element is still on the stacks.

Indentation is decided when a child starts, before later text is known. So an element that will hold text after markup is declared with `mixedContent`; the setting is inherited. `Document.write` knows the whole tree and declares it itself.

## Tests

| Where | What |
|---|---|
| unit tests beside the code | behaviour of one module, allocation failure |
| `src/tests.zig` | cases by production, limits, positions, namespaces, encodings, chunked input |
| `src/property_tests.zig` | generated and damaged documents: no crash or leak; accepted ones write back as the same tree |
| `src/api_examples.zig` | the examples of `api.md` |
| `tests/cli.sh` | the `xml-parse` command line |
| `bench/conformance.zig` | the W3C suite (`zig build conformance`), with `conformance_excused.txt` |
