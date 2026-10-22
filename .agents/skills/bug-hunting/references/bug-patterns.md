# Bug patterns

Read when localising (step 3) and stuck, or when reviewing code for correctness. Each row names the failure, the shape that reveals it, and the test that catches it. None of these are findings on their own — they are places to look.

## Boundaries

| Pattern | Shape | Test that catches it |
|---|---|---|
| Off-by-one | `<=` vs `<`, `len() - 1`, `range(n+1)` | Empty, one-element, and exactly-at-limit inputs |
| Empty vs null | `if not x:` treating `""` as missing | `""`, `[]`, `{}`, `0`, `False` separately |
| Unbounded input | read/parse with no cap | A body larger than any real one; a chunked response (`Content-Length: -1`) |
| Truncation | `.take(n)`, fixed buffers, `substr` | Input one byte over the limit |
| Encoding | `str` vs `bytes`, UTF-8 vs Latin-1, NFC vs NFD | Non-ASCII, emoji, combining characters, lone surrogates |
| Case sensitivity | lookups and comparisons on user text | `UPPER`, `MiXeD`, Turkish `İ` |

## State and lifetime

| Pattern | Shape | Test that catches it |
|---|---|---|
| Check-then-act race | `if exists:` then use | Two concurrent callers |
| Lost update | read-modify-write without a transaction | Interleaved writes |
| Leak | resource opened outside `try/finally` or `use` | Loop that opens 10 000 times, observe handles |
| Use after close | `disconnect()` then read | Read after the early return |
| Stale cache | keyed on the wrong identity, no invalidation | Change the underlying value, read again |
| Duplicate work | retry without an idempotency key | Deliver the same message twice |

## Error paths

| Pattern | Shape | Test that catches it |
|---|---|---|
| Swallowed error | `except Exception: pass` | Force the exception; assert the failure is visible |
| Wrong error | `KeyError` reported as "not found" | Missing key vs missing object |
| Partial commit | write A, then B fails | Fail B; assert A is rolled back |
| Cleanup skipped | `return` inside `try` before `finally` | Trigger the early return |
| Retry storm | unbounded retries, no backoff | Peer that always 500s |

## Time

| Pattern | Shape | Test that catches it |
|---|---|---|
| Timezone | naive datetime compared to aware | Run with `TZ=Pacific/Kiritimati` and `TZ=UTC` |
| DST | arithmetic on wall-clock time | The hour that repeats or is skipped |
| Ordering | sort by string timestamp | `…10:00` vs `…9:00` |
| Leap/epoch | `now + 86400` for "tomorrow" | Month ends, leap day |

## Concurrency

| Pattern | Shape | Test that catches it |
|---|---|---|
| Deadlock | two locks acquired in different orders | Two threads, reversed order, timeout |
| Unbounded pool | `new Thread` per request | Burst of 1 000 |
| Missing lock | shared mutable state across coroutines | Interleaved increments, check the total |
| Await on the wrong thread | UI-affecting work off the main thread | Assert the thread in the handler |

## Interfaces between layers

Most "impossible" bugs are two systems disagreeing about a contract:

- JSON `null` vs absent key; numbers as strings; int64 precision lost in JS.
- Form vs JSON encoding; `+` as space; repeated query parameters.
- Trailing slash, URL-encoded path, `..` normalisation.
- Integer width and signedness across a language boundary; `Long` vs `Double`.
- Time zone and clock skew between client and server.
- File path separators and case-insensitive filesystems.

The test is always the same: assert the value on **both sides** of the boundary, not on the side you wrote.

## The three questions that find the cause

1. **What is the smallest input that still fails, and what does it have that the passing one does not?**
2. **Where does that difference first appear as a wrong value?** Instrument the boundary, not the interior.
3. **What invariant did that value violate?** That sentence is the bug report's title.

If you cannot answer (2), you are guessing about (3).
