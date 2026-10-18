"""ASGI wrapper around Kokoro-FastAPI's own app (we never patch upstream files).

Why this exists: Kokoro serves its web player under /web/ and has no route at
"/". llama-swap's engine-UI button opens /upstream/<model>/ (hardcoded in its
own UI) and its /upstream/ passthrough strips that prefix before proxying, so

  * GET /upstream/<model>/        -> upstream 404, the button looks broken
  * GET /upstream/<model>/web     -> upstream 307 with an *absolute* Location
                                     (http://host/web/) built from the Host
                                     header, i.e. it escapes to the proxy root

Both are fixed here by wrapping the app: for exactly those three paths we hand
back a *relative* redirect to "web/", which a browser resolves against the
current URL, so it lands on <prefix>/web/ through llama-swap and on /web/ when
Kokoro is reached directly. Everything else is passed to upstream untouched,
and if upstream ever starts serving those paths itself (a real response, not a
404 or a redirect) we stay out of the way.

Imported as `kokoro_asgi_app:app` by container-files/kokoro-launcher.sh, with
$KOKORO_HOME/bin on PYTHONPATH. Set KOKORO_ROOT_REDIRECT=false in the model's
env: to run upstream's app directly instead.
"""

from api.src.main import app as upstream_app  # same import path upstream's entrypoint uses

# paths we may answer with a redirect, and the relative target for each
_REDIRECTS = {
    "": "web/",
    "/": "web/",
    "/web": "web/",
}


def _redirect_response(scope):
    """A 307 with a relative Location; browsers resolve it against scope['path']."""
    return {
        "type": "http.response.start",
        "status": 307,
        "headers": [
            (b"location", _REDIRECTS[scope.get("path", "")].encode("latin-1")),
            (b"content-length", b"0"),
            (b"cache-control", b"no-store"),
        ],
    }


async def app(scope, receive, send):
    """Upstream's app, except that bare /, /web and the empty path redirect to web/."""
    if scope["type"] != "http" or scope.get("path", "") not in _REDIRECTS:
        await upstream_app(scope, receive, send)
        return

    # Ask upstream first, buffering the answer: only a clean 404 or a redirect
    # gets replaced, so this cannot mask a route upstream adds later on. If
    # upstream raises, the exception propagates as it would without the wrapper.
    buffered = []

    async def buffering_send(message):
        buffered.append(message)

    await upstream_app(scope, receive, buffering_send)

    first = buffered[0] if buffered else None
    if first is not None and first["type"] == "http.response.start":
        status = first["status"]
        if status != 404 and status not in (301, 302, 303, 307, 308):
            for message in buffered:
                await send(message)
            return

    await send(_redirect_response(scope))
