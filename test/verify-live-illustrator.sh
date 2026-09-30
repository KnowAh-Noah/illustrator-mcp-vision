#!/usr/bin/env bash
# End-to-end verification against a live, running extension inside Illustrator.
#
# This exercises the whole stack:
# CEP Node -> HTTP -> MCP protocol -> evalScript -> ExtendScript -> Illustrator.
# Nothing is stubbed. It opens a scratch document, draws into it, captures it,
# and closes it without saving - it never touches a document you have open.

set -uo pipefail

PORT="${ILLUSTRATOR_MCP_PORT:-8792}"
# Must match TOKEN_FILE in cep/server/http-server.js. The token lives in the
# user's home directory and persists across Illustrator restarts.
TOKEN_FILE="$HOME/.illustrator-mcp-vision/token"
PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL+1)); }

if ! pgrep -f "Illustrator.app/Contents/MacOS/Adobe Illustrator" >/dev/null 2>&1; then
  echo "Illustrator is not running." >&2; exit 2
fi

if [ ! -f "$TOKEN_FILE" ]; then
  bad "token file exists" "no token at $TOKEN_FILE - the extension never started (bring Illustrator to the front once)"
  echo; echo "0/1 passed"; exit 1
fi
TOKEN="$(cat "$TOKEN_FILE")"
ok "token file present"

mcp() {
  curl -s --max-time 60 -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$1"
}
tool() { mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
field() { python3 -c "import sys,json;print(json.loads(json.load(sys.stdin)['result']['content'][-1]['text'])$1)" 2>/dev/null; }

H="$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")"
if echo "$H" | grep -q '"ok":true'; then
  ok "health endpoint responds"
  echo "$H" | grep -q '"reachable":true' && ok "ExtendScript host reachable through evalScript" || bad "ExtendScript host reachable" "$H"
else
  bad "health endpoint responds" "${H:-no response - is the extension loaded?}"
fi

# Match on serverInfo, not the bare service name: an unauthorized response
# quotes the token path, which also contains the service name.
R="$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')"
echo "$R" | grep -q '"serverInfo"' && ok "MCP initialize" || bad "MCP initialize" "$R"

R="$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
COUNT="$(echo "$R" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))' 2>/dev/null || echo 0)"
[ "$COUNT" = "10" ] && ok "tools/list returns 10 tools" || bad "tools/list returns 10 tools" "got $COUNT"

R="$(tool ai_query '{"command":"sessionInfo"}')"
echo "$R" | grep -q 'appVersion' && ok "ai_query sessionInfo through the full stack" || bad "ai_query sessionInfo" "$R"

R="$(tool ai_document '{"command":"new","width":400,"height":300}')"
DOC="$(echo "$R" | field "['name']")"
[ -n "$DOC" ] && ok "scratch document $DOC" || { bad "ai_document new" "$R"; echo; echo "$PASS passed, $FAIL failed"; exit 1; }

R="$(tool ai_create '{"kind":"rect","x":40,"y":40,"width":120,"height":80,"fill":"#FF5A36"}')"
BOX="$(echo "$R" | field "['box']")"
[ "$BOX" = "{'x': 40, 'y': 40, 'width': 120, 'height': 80}" ] && ok "ai_create lands exactly where asked" || bad "ai_create box" "$R"

R="$(tool ai_capture '{"command":"artboard","longEdge":256}')"
if echo "$R" | grep -q '"type":"image"'; then
  ok "ai_capture returned a real image"
  echo "$R" | python3 -c 'import sys,json,base64,pathlib,tempfile,os;d=json.load(sys.stdin);p=os.path.join(tempfile.gettempdir(),"illustrator-live-capture.png");pathlib.Path(p).write_bytes(base64.b64decode(d["result"]["content"][0]["data"]));print("        wrote "+p)' 2>/dev/null
else
  bad "ai_capture" "$R"
fi

# Regressions found building real award graphics (2026-09-29/30). Each ran
# clean in unit tests and failed only against the real app.
T="$(tool ai_create '{"kind":"text","x":40,"y":160,"contents":"Size check","size":24}')"
TU="$(echo "$T" | field "['uuid']")"
R="$(tool ai_query "{\"command\":\"item\",\"uuid\":\"$TU\"}")"
[ "$(echo "$R" | field "['text']['size']")" = "24.0" ] || [ "$(echo "$R" | field "['text']['size']")" = "24" ] \
  && ok "text attributes read back (were null: second textRange invalidated the first)" \
  || bad "text attributes read back" "$R"

WORK="$(mktemp -d)"
python3 - "$WORK/logo.png" <<'PY'
import struct, zlib, sys
w, h = 40, 20
raw = b''.join(b'\x00' + b'\xff\x5a\x36\xff' * w for _ in range(h))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
  + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
PY
R="$(tool ai_create "{\"kind\":\"image\",\"path\":\"$WORK/logo.png\",\"x\":200,\"y\":40,\"width\":100,\"height\":100}")"
[ "$(echo "$R" | field "['type']")" = "RasterItem" ] && [ "$(echo "$R" | field "['box']['width']")" = "100" ] \
  && ok "ai_create image places, embeds and fits the box" || bad "ai_create image" "$R"

A="$(tool ai_create '{"kind":"rect","x":40,"y":220,"width":20,"height":20}')"
B="$(tool ai_create '{"kind":"rect","x":70,"y":220,"width":20,"height":20}')"
AU="$(echo "$A" | field "['uuid']")"; BU="$(echo "$B" | field "['uuid']")"
tool ai_items "{\"command\":\"group\",\"uuids\":[\"$AU\",\"$BU\"]}" >/dev/null
R="$(tool ai_query '{"command":"find","type":"PathItem","topLevel":true}')"
echo "$R" | grep -q "$AU" && bad "find topLevel" "grouped item $AU listed as top-level" \
  || ok "find topLevel leaves out items inside groups"
tool ai_query '{"command":"find","type":"PathItem"}' | grep -q 'parentUuid' \
  && ok "find marks nested items with parentUuid" || bad "find parentUuid" "no parentUuid on grouped items"

R="$(tool ai_export "{\"path\":\"$WORK/Name With Spaces.png\",\"scale\":20}")"
P="$(echo "$R" | field "['path']")"
[ -n "$P" ] && [ "$P" != "None" ] && [ -f "$P" ] \
  && ok "ai_export reports the file it wrote ($(basename "$P"))" || bad "ai_export path" "$R"

R="$(tool ai_document '{"command":"addArtboard","x":30000,"y":0,"width":100,"height":100}')"
echo "$R" | grep -q "outside Illustrator's canvas" \
  && ok "artboard past the canvas gets a readable error" || bad "canvas error" "$R"
rm -rf "$WORK"

R="$(tool ai_diagnostics '{}')"
echo "$R" | grep -q 'overflowingText' && ok "ai_diagnostics" || bad "ai_diagnostics" "$R"

R="$(tool ai_document "{\"command\":\"activate\",\"name\":\"$DOC\"}")"
R="$(tool ai_document '{"command":"close","discardUnsaved":true}')"
echo "$R" | grep -q 'remaining' && ok "scratch document closed without saving" || bad "close scratch document" "$R"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
