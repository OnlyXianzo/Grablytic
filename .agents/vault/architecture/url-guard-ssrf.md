---
title: URL Guard (SSRF Boundary)
date: 2026-10-08
tags: [grablytic, architecture, security, ssrf, engine]
status: complete
---

# URL Guard (SSRF Boundary)

Every IPC-controlled string that reaches the network, filesystem, or proxy passes through `engine/grablytic_engine/url_guard.py` (286 lines) first. Repo paths: `[[url-guard-ssrf|url_guard.py]]`, `engine/tests/test_url_guard_ssrf.py`, `engine/tests/test_url_guard.py`.

> **Not a new module.** It predates the 2026-09-30 vault scope — `docs/CHANGELOG.md:67` records `6ec6e27b6 fix(engine): gate SSRF targets and validate proxy at every sink` in v0.0.4 (2026-09-17), and `:72` records `b01cd426c fix(engine): close SSRF bypasses in url_guard non-decimal IP forms and DNS names`. The vault simply never covered it. It is also why [[system-overview|system-overview]]'s module count was wrong (18 recorded vs **19** actual).

## Design contract

Module docstring (`url_guard.py:1-7`):

> "Every IPC-controlled string used to reach the network (media URLs, site profile override URLs) or to the filesystem (download-archive path) or to redirect all traffic (proxy) passes through here first. stdlib only. **Never raises: validators return ""/None on garbage (fail closed).**"

Three sinks: network (media/profile URLs), filesystem (`safe_archive_path`), traffic redirection (`sanitized_proxy`).

## Public API

| Function | Line | Policy |
|---|---|---|
| `is_safe_media_url(url)` | `:209` | Scheme allowlist + host validation + no userinfo + length ≤2048 |
| `is_safe_profile_url(url)` | `:237` | Delegates to `is_safe_media_url` (no separate policy) |
| `sanitized_proxy(proxy)` | `:242` | **No private-host block** (see below) |
| `safe_archive_path(base, candidate)` | `:267` | `realpath` both sides + `os.path.commonpath` containment |

Re-exported as public API in `engine/grablytic_engine/__init__.py:20-25,65-68`.

### Scheme allowlists

```python
_ALLOWED_MEDIA_SCHEMES = ("http", "https")                          # url_guard.py:14
_ALLOWED_PROXY_SCHEMES = ("http", "https", "socks4", "socks5", "socks5h")  # :15
```

### Host blocklist (`url_guard.py:17-22`)

```python
_LOCAL_HOSTS = {"localhost", "localhost.", "0.0.0.0", "::", "::1"}
_CLOUD_METADATA_IPV4 = ipaddress.ip_address("169.254.169.254")
_IPV6_LINK_LOCAL  = ipaddress.ip_network("fe80::/10")
_IPV6_UNIQUE_LOCAL = ipaddress.ip_network("fc00::/7")
```

`is_safe_media_url` additionally rejects non-`str` (`:216`), empty or `len > 2048` (`:219`), `urlparse` failure (`:221`), non-`http(s)` scheme (`:225` — blocks `file://`, `ftp://`, `gopher://`), **embedded userinfo** `parts.username or parts.password` (`:227`), and empty host (`:229`).

`_host_is_blocked` (`:144-206`) runs four gates:

1. Normalize: lowercase, strip trailing `.`, strip IPv6 zone id (`%eth0`), reject empty, reject `_LOCAL_HOSTS` and any `*.local` / `*.localhost` (`:145-153`).
2. Direct literal via `ipaddress.ip_address` → `_ip_is_blocked` (`:156-161`).
3. **Alternative IPv4 encodings canonicalized to a 32-bit int** via `_alt_ipv4_to_int` (`:58-104`): bare decimal (`2130706433`), hex (`0x7f000001`), octal (`0177.0.0.1`), and short inet_aton forms `a.b.c` / `a.b` (`:87-102`). `_parse_numeric_part` (`:25-55`) handles `0x`/`0X`, `0o`, leading-`0` octal, and falls back to decimal for `09` — "matching browsers".
4. **DNS-rebinding guard** (`:172-206`): `socket.getaddrinfo(h, 80, type=SOCK_STREAM)`; blocked if **ANY** returned address is non-public, plus an explicit `169.254.169.254` re-check (`:204-205`).

`_ip_is_blocked` (`:107-141`) flags `is_private or is_loopback or is_link_local or is_multicast or is_reserved or is_unspecified`, plus the four explicit pins (`:131-137`).

## Fail-open vs fail-closed — the precise split

| Situation | Behaviour | Citation |
|---|---|---|
| Any validator on garbage / exception | **FAIL CLOSED** (`False`/`""`/`None`) | `:6`, `:216-224`, `:251-259`, `:285-286` |
| `_ip_is_blocked` on uninspectable address | **FAIL CLOSED** → `True` | `:139-141` — *"an uninspectable address never counts as public"* |
| `_alt_ipv4_to_int` bad/oversized numeric part | **FAIL CLOSED** → `None` → hostname path | `:75-102` |
| `_host_is_blocked` on **DNS `gaierror`** | **FAIL OPEN** (allowed) | `:176-182` |
| `_host_is_blocked` on unexpected resolver exception | **FAIL OPEN** | `:183-185` |
| `_host_is_blocked` on empty `infos` | **FAIL OPEN** | `:186-187` |
| `start_download` guard wrapper on import/exception | **FAIL CLOSED** → `_url_ok = False` | `downloader.py:1257-1261` |

The fail-open is a **deliberate, self-documented residual** (`url_guard.py:177-181`):

> "Known residual: on DNS failure we cannot prove rebinding, so fail OPEN (not blocked) to avoid bricking legitimate downloads while offline or with broken DNS. Residual risk: an attacker hostname rebound during an outage slips past; redirect re-validation inside yt-dlp is out of scope for this ticket."

## Why `sanitized_proxy` has no private-host block

Verbatim from `url_guard.py:243-249`:

> "Auth userinfo (user:pass@host) is preserved — proxies legitimately carry credentials (including localhost ones such as Tor on 127.0.0.1:9050), so unlike media URLs there is no private-host block here, only scheme+host validation"

It requires `isinstance(str)`, non-empty, `len <= 1024` (`:254`), `urlparse` success (`:256`), scheme in `_ALLOWED_PROXY_SCHEMES` (`:260`), non-empty hostname (`:262`).

## Production call sites

| Caller | Line | Use |
|---|---|---|
| `downloader.start_download` | `downloader.py:1254-1268` | `is_safe_media_url(url)`; on reject returns `{"success": False, "error_type": "ERROR_INVALID_PARAM", "error_message": "URL must be a public http(s) address"}` **before admission, queueing, or thread spawn** |
| `formats.get_formats` | `formats.py:18-24` | same guard, same error shape |
| `playlist.get_playlist_info` | `playlist.py:74-80` | same guard, same error shape |
| `site_profiles.load_site_profiles_from_url` | `site_profiles.py:76-78` | `is_safe_profile_url`; on reject **silently** falls back to `load_site_profiles()` — no error surfaced |
| `opts_builder.build_ydl_opts` | `opts_builder.py:455-467` | `sanitized_proxy`; on `""` logs WARN `"Ignoring malformed proxy setting (expected http/https/socks URL with host)"` and omits `opts["proxy"]` |
| `formats.py:52-54`, `playlist.py:110-112` | | `sanitized_proxy` for the extractor `proxy` opt |
| `search.search_query` | `search.py:69-72` | `sanitized_proxy` **only** — no media-URL gate |

## Known gaps

- **`safe_archive_path` has zero production callers.** Repo-wide it appears only at `url_guard.py:267`, `__init__.py:23,67`, and `engine/tests/test_url_guard.py:56-67`.
- `downloader.clear_download_archive` re-implements containment **inline with a different primitive** (`downloader.py:1662-1670`): `path.startswith(resolved_data_dir + os.sep)`, versus `os.path.commonpath` in `url_guard.py:280`. The docstring claim at `url_guard.py:269-270` ("Mirrors clear_download_archive's real-path containment") is approximately, not literally, true.
- `search.py` has no media-URL gate (search only takes a query string, so this may be intentional).

## Tests

`engine/tests/test_url_guard_ssrf.py` (117 lines):
- `TestSsrfBypasses` — decimal-int loopback `http://2130706433/foo` (`:25`), hex `http://0x7f000001/foo` (`:28`), octal `http://0177.0.0.1/foo` (`:31`), DNS-rebinding `127.0.0.1.nip.io` via monkeypatched `getaddrinfo` (`:33-42`), `169.254.169.254.nip.io` (`:44-59`), plain loopback (`:62`) — all rejected.
- `TestLegitimateUrls` — youtube watch URL (`:67-84`), example.com (`:86-101`) accepted; `file://`/`gopher://`/`ftp://` (`:103-106`) and `192.168.1.50:8096` (`:108-109`) rejected; **`test_dns_failure_fails_open`** (`:111-117`) monkeypatches `getaddrinfo` to raise `gaierror` and asserts `is_safe_media_url("https://example.com/video") is True`.

`engine/tests/test_url_guard.py` covers the older surface: localhost/127.0.0.1/192.168.1.1/10.0.0.5/169.254.169.254 literals, `user:pass@evil.test` (`:31`), non-string inputs (`:34-35`), `sanitized_proxy` allowing `socks5h://127.0.0.1:9050` and `user:pw@proxy.test:3128` while rejecting `"--proxy http://evil:8080"` (`:45-53`), and `safe_archive_path` traversal rejection (`:60-67`).

## Links

- [[index|index]]
- [[system-overview|system-overview]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[storage-layout|storage-layout]]
- [[triage-export-workflow|triage-export-workflow]]
- [[open-questions|open-questions]]
