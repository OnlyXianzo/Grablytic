# Surface checklist

Read this when building the surface map (step 1) or when a category feels "obviously fine". It is an index of questions, not a list of findings. Every item still needs a path from an entry point to a sink.

## Injection

| Question | Looks like | Standards |
|---|---|---|
| Is any query built by concatenation, f-string, or template? | `f"SELECT … {user}"`, `.format()`, string `+` near `cursor` | A03, CWE-89, ASVS 5.3.4 |
| Does `shell=True` / `Runtime.exec(String)` / `child_process.exec` receive input? | `subprocess.run(cmd, shell=True)`, `exec("sh -c " + x)` | A03, CWE-78 |
| Is an LDAP filter, XPath, or template expression evaluated with input? | `ldap_search(f"(uid={u})")`, Jinja `Template(user)` | A03, CWE-90/643/1336 |
| Is a document parsed with entity expansion enabled? | `FEATURE_PROCESS_DOCDECL=true`, `resolve_entities=True` | A05, CWE-611/776 |
| Is user input compiled as code? | `eval`, `new Function`, `exec`, `pickle.loads` | A08, CWE-95/502 |

## Access control

- Every route/handler: is authorisation checked **inside** the handler, on the object, not only on the route group?
- Does any lookup take an ID and return the object without an ownership predicate? (IDOR)
- Can a role escalate by supplying a field (`role`, `isAdmin`, `ownerId`) in a request body?
- Is a privileged operation reachable from a lower-privileged surface (mobile API, deep link, IPC, exported component)?
- Android/iOS: exported components, `PendingIntent` mutability, deep-link validation, `content://` provider roots.
- Standards: A01, CWE-639/284/862/926, API1/API5.

## Authentication and session

- Token validation: signature, algorithm pinning (no `alg: none`), audience, issuer, expiry, clock skew.
- Session fixation, rotation on privilege change, revocation, server-side vs stateless trade-off.
- Password storage: modern KDF with cost parameters, salt per user, no pepper in the repo.
- MFA bypass paths: recovery, "remember me", API endpoints that skip the check.
- Standards: A07, CWE-287/384/613, ASVS V2/V3.

## Crypto and secrets

- Hardcoded keys, tokens, keystores, or certificates — including in tests, fixtures, and CI.
- `random` vs `secrets`/`SecureRandom` for anything security-relevant.
- ECB mode, static IV, reused nonce, missing MAC, custom constructions.
- TLS verification disabled (`verify=False`, `TrustAllCerts`, hostname verifier returning true).
- Standards: A02, CWE-798/327/330/295/916.

## Data exposure

- What reaches logs, crash reports, analytics, or a user-facing issue tracker? Cookies, tokens, paths, PII.
- Redaction that exists but is incomplete (a pattern that stops at whitespace, a case-sensitive gate under a case-insensitive rule).
- Error responses that leak stack traces, SQL, or internal hosts.
- Standards: A09, CWE-209/532/200.

## SSRF, paths, files

- Is a URL fetched with a client that follows redirects? The guard must own the redirect behaviour, not just the first hop.
- Is the host compared with a parse (`URI.getHost()` equality) or a regex? Regex loses.
- Path joins: `..`, absolute paths, symlinks, prefix siblings (`/root/dl` vs `/root/dl-evil`), unresolvable roots.
- Archive extraction: entry names with `..`, absolute paths, symlink entries, decompression bombs.
- Uploads: content-type trust, extension trust, storage location, executable permissions.
- Standards: A10, CWE-918/22/409/434/502, API7.

## Concurrency and business logic

- Check-then-act on shared state without a lock or a transaction; double-spend, double-claim.
- Unbounded queues, thread pools, or retry loops; missing idempotency keys.
- TOCTOU between a security check and the operation it protects.
- Money, quota, or rate limits enforced client-side.
- Standards: CWE-362/367/840, API4/API6.

## Resource limits (availability)

- Any read of a network body without a byte cap? A chunked response reports `-1` for content length.
- Any parse that retains every element (feeds, CSV, JSON arrays)?
- Read timeout vs total-transfer timeout: a slow drip defeats the former.
- Regex with nested quantifiers on attacker-controlled text.
- Standards: CWE-400/770/1333, API4.

## Supply chain and build

- Lockfiles present and committed; dependency versions not floating.
- CI actions pinned to full commit SHAs, not tags. Workflow `permissions:` least privilege.
- Build scripts that fetch and execute remote code.
- Known CVEs: check the version, not the name. "Old" is not a finding; an affected range is.
- Standards: A06/A08, CWE-1104/829, SLSA, SSDF.

## Language-specific quick hits

- **Python:** `pickle`/`yaml.load` on untrusted input, `subprocess` with `shell=True`, `assert` for security checks (stripped under `-O`), mutable default args, `eval` in templates.
- **Kotlin/Java:** exported components, implicit `PendingIntent`, `WebView` JS bridge, `TrustManager` overrides, deserialisation of Java objects, `Runtime.exec` with a string.
- **Dart/Flutter:** `MethodChannel` handlers that trust the Dart side, `WebView` JS channels, path handling on the native side of a plugin, secrets in `--dart-define`.
- **JS/TS:** prototype pollution via `Object.assign`/merge, `eval`, `dangerouslySetInnerHTML`, `child_process.exec`, JWT `alg` confusion.
- **Go:** `text/template` for HTML, `exec.Command("sh","-c",…)`, unchecked `filepath.Join` with user input.

## What to write for a clean category

> **Injection — no evidence within supplied scope.** All 34 query sites use parameter binding (`grep -n "execute(" engine/ | wc -l` = 34; the only string-built SQL is a table name selected from a constant allowlist at `db.py:88`). Not covered: the vendored migration tool in `vendor/`, excluded from scope.

That is a result. "No injection issues found" is not.
