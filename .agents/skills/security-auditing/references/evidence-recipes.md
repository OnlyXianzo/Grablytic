# Evidence recipes

Read this when a hypothesis needs a decision (workflow step 3). Each recipe states what it proves and what it does not — paste that caveat into the finding, because the distinction is the difference between an audit and a guess.

## The execution ladder

Before writing "confirmed", ask what you actually ran:

| Level | Evidence | Say this |
|---|---|---|
| 1 | The shipped code executed and its output is quoted | Confirmed from execution |
| 2 | The shipped *decision logic* ported 1:1 and executed against hostile inputs | Confirmed from execution, of the algorithm; compilation unverified |
| 3 | The source was read and quoted with file:line | Confirmed from code |
| 4 | Upstream semantics read in docs or source | Strongly indicated (name the assumption) |
| 5 | Neither available | Requires verification (name the experiment) |

Level 2 is the workhorse when the target language is missing. Port **the policy, not the platform**: same order of checks, same accessors, same regex. If the Kotlin calls `URI(raw).host`, the Java harness must call `new URI(raw).getHost()` — not a hand-rolled host parser that you wrote while thinking about the bug.

## Redirect hop

A validator on the first URL is not a validator if the client follows redirects.

```java
// Two servers: an "internal" target that counts hits, and a "public" one that 302s to it.
HttpServer internal = HttpServer.create(new InetSocketAddress("127.0.0.1", 9101), 0);
AtomicInteger hits = new AtomicInteger();
internal.createContext("/", ex -> { hits.incrementAndGet(); /* 200 */ });

HttpURLConnection c = (HttpURLConnection) new URL("http://127.0.0.1:9100/redirect").openConnection();
c.setInstanceFollowRedirects(false);        // the fix
int code = c.getResponseCode();
System.out.println("code=" + code + " hits=" + hits.get());
```

`hits=1` with the default and `hits=0` with the flag off is the whole proof. The same shape works in Python (`allow_redirects=False`), Dart (`followRedirects=false`), and Go (`CheckRedirect`). **Proves:** the client's behaviour. **Does not prove:** that the application set the flag — check the call site.

## Timeout vs slow drip

`readTimeout` bounds one read, not the transfer. A byte every 300 ms keeps a socket open forever.

```python
srv = socket.socket(); srv.bind(("127.0.0.1", 9102)); srv.listen(1)
# accept, send headers, then one byte per 300ms; measure how long the client stays open
```

Compare the observed open time against the timeout you think is configured. **Proves:** the resource bound is missing. **Does not prove:** exhaustion — multiply by connections and say so.

For the fix, test the cap at the boundary, not just over it: a body of exactly the limit must parse, one byte more must fail. A `limit` wrapper that returns EOF instead of throwing turns a size attack into a silent truncation that parses as valid-but-wrong.

## Path containment

The four cases a string prefix check gets wrong:

```
/root/dl        vs /root/dl-evil/x      sibling prefix
/root/dl/../secret/keys.txt             traversal
/root/dl/escape -> /root/secret         symlink out
root = ""  |  root = "."  |  root = "/" fail-closed inputs
```

Build real files and real symlinks in a temp dir; do not simulate them. `Files.createSymbolicLink` on a non-privileged filesystem works on macOS/Linux and usually on Windows with developer mode. **Proves:** the policy. **Does not prove:** the caller uses it — grep for the call site and confirm the guarded value is the one that reaches the sink.

## Regex safety

Time the pathological input rather than reasoning about it. Generate 40 000 separators and 20 000 nested segments, and assert the run is linear:

```python
t = time.perf_counter(); pattern.sub("x", "/" + "a/" * 20000 + "b")
assert time.perf_counter() - t < 0.5
```

Disjoint repeats (a segment that cannot contain the separator) are linear; nested quantifiers (`(a+)+`) are not. **Proves:** this pattern on this input. **Does not prove:** every input — say which shapes you tried.

## Red → green

The only test that a fix addresses a finding:

```bash
git checkout -q <parent-sha>          # pre-fix
cp -r . /tmp/pre && cd /tmp/pre
<run the new regression test>         # must FAIL, for the right reason
cd - && git checkout -q <fix-sha>
<run the same test>                   # must PASS
```

A test that was already passing proves nothing. A test that fails on a missing import proves nothing. Quote both outputs.

## Deserialisation and archive extraction

- **Deserialisation:** does the format allow class resolution (`pickle`, Java `readObject`, `yaml.load`)? Demonstrate with a benign marker class if you can; if you cannot, say the sink is reachable and list the gadget question as unresolved rather than writing an exploit you did not build.
- **Archive:** create an entry named `../../x` and an entry that is a symlink to `/etc/passwd`. Extraction either refuses or writes outside the target. Check the real extraction call, not a hand-rolled loop.

## When you truly cannot execute

Write the experiment instead of the conclusion:

> **Requires verification.** If `FeedClient` is constructed with `followRedirects = true` (default `true` in the framework, not verified here), the guard at `:501` is bypassed by a 302. Experiment: point the feed URL at a local server that 302s to `http://127.0.0.1:9101/` and count hits. Expected if vulnerable: 1.

A maintainer can run that. A severity with no experiment behind it, they cannot.
