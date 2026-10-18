"""ASGI wrapper around Kokoro-FastAPI's own app (we never patch upstream files).

Kokoro's web player is written for a server that owns the whole URL space, and
llama-swap serves it under a prefix (/upstream/<model>/...) and with its own
default request limits, which breaks three things. All three are repaired here,
by wrapping the app rather than editing upstream's files:

  * llama-swap's "open engine UI" button opens /upstream/<model>/, and Kokoro has
    no route at "/" (404). Its "/web" -> "/web/" redirect is worse: Starlette
    builds it from the Host header, so it comes back absolute
    (http://host/web/) and escapes to the proxy root.
    Fix: for exactly "", "/" and "/web" we answer a *relative* redirect to
    "web/", which browsers resolve against the current URL, so it lands on
    <prefix>/web/ through llama-swap and on /web/ when reached directly.

  * web/src/config.js auto-detects the URL prefix, then overwrites that guess
    with the "root_path" field of /web/config, which upstream fills from the
    UVICORN_ROOT_PATH environment variable - unset in our image, so it reports
    "" and the player starts calling /v1/... at the proxy root (404, empty voice
    list, half the UI missing).
    Fix: rewrite that JSON field to the prefix the browser is really under. The
    request path cannot tell us (llama-swap strips the prefix before proxying),
    so it is taken from the browser's Referer - which is the page URL, e.g.
    <prefix>/web/ - falling back to the request path (works when the proxy keeps
    it), and KOKORO_ROOT_PATH in the model's env: forces it. uvicorn's own
    --root-path is deliberately NOT used: it would also apply to the unprefixed
    /v1/... calls that llama-swap proxies, which must keep matching.

Everything else is passed to upstream untouched, and the redirects only replace a
404 or a redirect, so if upstream ever serves those paths itself we step aside.
root_path rewriting is skipped if you set UVICORN_ROOT_PATH yourself.

Imported as `kokoro_asgi_app:app` by container-files/kokoro-launcher.sh, with
$KOKORO_HOME/bin on PYTHONPATH. KOKORO_ROOT_REDIRECT=false in the model's env:
skips this wrapper entirely and runs upstream's app as-is (the engine-UI button
then 404s again, exactly as upstream ships it).
"""

import json
import os
import urllib.parse

from api.src.main import app as upstream_app  # same import path upstream's entrypoint uses

# paths we may answer with a redirect, and the relative target for each
_REDIRECTS = {
    "": "web/",
    "/": "web/",
    "/web": "web/",
}

_WEB_CONFIG = "/web/config"
_REDIRECT_STATUS = (301, 302, 303, 307, 308)


async def _call_upstream_buffered(scope, receive):
    """Run upstream with `scope`, collecting its whole (small) response.

    Returns (start_message, headers, body, raw_messages). Raises whatever upstream
    raises, so a real failure propagates exactly as it would without this wrapper.
    """
    buffered = []

    async def buffering_send(message):
        buffered.append(message)

    await upstream_app(scope, receive, buffering_send)

    start = next((m for m in buffered if m["type"] == "http.response.start"), None)
    headers = list(start["headers"]) if start else []
    body = b"".join(m.get("body", b"") for m in buffered if m["type"] == "http.response.body")
    return start, headers, body, buffered


def _header(headers, name):
    name = name.lower().encode("latin-1")
    for key, value in headers:
        if key.lower() == name:
            return value.decode("latin-1")
    return ""


def _redirect_response(target):
    """A 307 with a relative Location; browsers resolve it against the request path."""
    return [
        {
            "type": "http.response.start",
            "status": 307,
            "headers": [
                (b"location", target.encode("latin-1")),
                (b"content-length", b"0"),
                (b"cache-control", b"no-store"),
            ],
        },
        {"type": "http.response.body", "body": b"", "more_body": False},
    ]


async def _handle_redirect(scope, receive, send):
    """Serve a relative redirect to web/ if upstream has nothing better for this path."""
    start, _, _, raw = await _call_upstream_buffered(scope, receive)
    status = start["status"] if start else 404
    if start is not None and status != 404 and status not in _REDIRECT_STATUS:
        # upstream answered for real, do not mask it
        for message in raw:
            await send(message)
        return
    for message in _redirect_response(_REDIRECTS[scope.get("path", "")]):
        await send(message)


def _root_path(scope):
    """The URL prefix the browser sees this server under ("" = served at the root).

    Precedence: an explicit KOKORO_ROOT_PATH, then the Referer (the player's page
    URL, which always sits at <prefix>/web/), then the request path itself.
    """
    forced = os.environ.get("KOKORO_ROOT_PATH")
    if forced is not None:
        return forced.rstrip("/")

    headers = scope.get("headers", [])
    referer = _header(headers, "referer")
    host = _header(headers, "host")
    if referer:
        parts = urllib.parse.urlsplit(referer)
        # ignore a referer from another host, and one with no path (cross-origin
        # pages send only their origin under the default referrer policy)
        if (not host or not parts.netloc or parts.netloc == host) and "/web" in parts.path:
            return parts.path.split("/web", 1)[0].rstrip("/")

    path = scope.get("path", "")
    if path.endswith(_WEB_CONFIG):
        return path[: -len(_WEB_CONFIG)].rstrip("/")
    return ""


async def _handle_web_config(scope, receive, send, root_path):
    """Re-report /web/config's root_path as the prefix this request came in on."""
    start, headers, body, raw = await _call_upstream_buffered(scope, receive)
    if start is None or start["status"] != 200 or "json" not in _header(headers, "content-type"):
        for message in raw:
            await send(message)
        return

    try:
        payload = json.loads(body.decode("utf-8"))
        payload["root_path"] = root_path
        patched = json.dumps(payload).encode("utf-8")
    except (ValueError, UnicodeDecodeError):
        patched = body

    keep = [(k, v) for k, v in headers if k.lower() not in (b"content-length", b"content-type")]
    keep.append((b"content-length", str(len(patched)).encode("latin-1")))
    await send({"type": "http.response.start", "status": start["status"], "headers": keep})
    await send({"type": "http.response.body", "body": patched, "more_body": False})


async def app(scope, receive, send):
    """Upstream's app, plus the two fixes described in the module docstring."""
    if scope["type"] != "http":
        await upstream_app(scope, receive, send)
        return

    path = scope.get("path", "")

    if os.environ.get("KOKORO_ROOT_REDIRECT", "true") == "true" and path in _REDIRECTS:
        await _handle_redirect(scope, receive, send)
        return

    # only GET: a HEAD must not get a rewritten content-length for a body it never sees
    if (
        scope.get("method") == "GET"
        and not os.environ.get("UVICORN_ROOT_PATH")
        and path.endswith(_WEB_CONFIG)
    ):
        await _handle_web_config(scope, receive, send, _root_path(scope))
        return

    await upstream_app(scope, receive, send)
