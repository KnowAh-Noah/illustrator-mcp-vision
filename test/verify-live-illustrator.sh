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
# Once the scratch document exists (DOC is set), every call is pinned to it:
# the server refuses a call whose document is not the active one, so nothing
# this script does can land in a file the user clicked into mid-run.
tool() {
  local args="$2"
  if [ -n "${DOC:-}" ]; then
    args="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.setdefault("document", sys.argv[2]); print(json.dumps(a))' "$2" "$DOC")"
  fi
  mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$args}}"
}
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
G="$(tool ai_items "{\"command\":\"group\",\"uuids\":[\"$AU\",\"$BU\"]}")"
GU="$(echo "$G" | field "['uuid']")"
# Absence only means something once the search itself is shown to work: assert
# the group exists and both searches return items before checking what is
# missing from them.
TOP="$(tool ai_query '{"command":"find","topLevel":true}')"
ALL="$(tool ai_query '{"command":"find","type":"PathItem"}')"
TOPN="$(echo "$TOP" | field "['count']")"; ALLN="$(echo "$ALL" | field "['count']")"
if [ -z "$GU" ] || [ "$GU" = "None" ] || [ -z "$TOPN" ] || [ "$TOPN" = "0" ] || [ -z "$ALLN" ] || [ "$ALLN" = "0" ]; then
  bad "find topLevel / parentUuid" "group or find failed: group=$GU top=$TOPN all=$ALLN"
else
  UUIDS="$(echo "$TOP" | python3 -c "import sys,json;print(' '.join(i['uuid'] for i in json.loads(json.load(sys.stdin)['result']['content'][-1]['text'])['items']))")"
  echo " $UUIDS " | grep -q " $GU " && ! echo " $UUIDS " | grep -q " $AU " \
    && ok "find topLevel lists the group and leaves out its children" \
    || bad "find topLevel" "expected group $GU present and child $AU absent: $TOP"
  [ "$(echo "$ALL" | python3 -c "import sys,json;d=json.loads(json.load(sys.stdin)['result']['content'][-1]['text']);print(any(i['uuid']=='$AU' and i.get('parentUuid')=='$GU' for i in d['items']))")" = "True" ] \
    && ok "find marks nested items with their group's parentUuid" || bad "find parentUuid" "$ALL"
fi

R="$(tool ai_export "{\"path\":\"$WORK/Name With Spaces.png\",\"scale\":20}")"
P="$(echo "$R" | field "['path']")"
[ -n "$P" ] && [ "$P" != "None" ] && [ -f "$P" ] \
  && ok "ai_export reports the file it wrote ($(basename "$P"))" || bad "ai_export path" "$R"

R="$(tool ai_document '{"command":"addArtboard","x":30000,"y":0,"width":100,"height":100}')"
echo "$R" | grep -q "outside Illustrator's canvas" \
  && ok "artboard past the canvas gets a readable error" || bad "canvas error" "$R"
rm -rf "$WORK"

# Review fixes on PR #10 - each of these could delete or overwrite work.
tool ai_layers '{"command":"create","name":"MCP Parent"}' >/dev/null
tool ai_layers '{"command":"create","name":"MCP Child","parent":["MCP Parent"]}' >/dev/null
tool ai_layers '{"command":"setActive","layer":["MCP Parent","MCP Child"]}' >/dev/null
tool ai_create '{"kind":"rect","x":300,"y":300,"width":10,"height":10}' >/dev/null
R="$(tool ai_layers '{"command":"delete","layer":["MCP Parent"]}')"
echo "$R" | grep -q "holds 1 items across it and 1 sublayer" \
  && ok "layer delete refuses a layer whose art is all in sublayers" || bad "layer delete sublayer guard" "$R"
R="$(tool ai_layers '{"command":"delete","layer":["MCP Parent"],"deleteContents":true}')"
[ "$(echo "$R" | field "['deleted']")" = "['MCP Parent']" ] && ok "layer delete with deleteContents:true removes it" || bad "layer delete deleteContents" "$R"
tool ai_layers '{"command":"setActive","layer":["Layer 1"]}' >/dev/null

EX="$(mktemp -d)"
R1="$(tool ai_export "{\"path\":\"$EX/Hero Banner.png\",\"scale\":10}")"
R2="$(tool ai_export "{\"path\":\"$EX/Hero Banner.png\",\"scale\":10}")"
[ -f "$EX/Hero Banner.png" ] && [ "$(echo "$R1" | field "['path']")" = "$EX/Hero Banner.png" ] \
  && ok "export writes exactly the name asked for" || bad "export name" "$R1 / $(ls "$EX")"
echo "$R2" | grep -q "pass overwrite:true" \
  && ok "a second export to the same name is refused without overwrite" || bad "export overwrite guard" "$R2"
printf 'old' > "$EX/logo-old.png"
R="$(tool ai_export "{\"path\":\"$EX/logo.png\",\"scale\":10}")"
[ "$(echo "$R" | field "['path']")" = "$EX/logo.png" ] && [ "$(cat "$EX/logo-old.png")" = "old" ] \
  && ok "export ignores a neighbour like logo-old.png" || bad "export neighbour" "$R"
R="$(tool ai_export "{\"path\":\"$EX/photo.jpeg\",\"scale\":10}")"
[ -f "$EX/photo.jpeg" ] && ok "export accepts .jpeg" || bad "export .jpeg" "$R"
rm -rf "$EX"

R="$(tool ai_query '{"command":"sessionInfo","document":"Not The Active Document.ai"}')"
echo "$R" | grep -q "wrong_document" && ok "a call pinned to another document is refused" || bad "document guard" "$R"
R="$(tool ai_query '{"command":"selection"}')"
[ "$(echo "$R" | field "['document']")" = "$DOC" ] && ok "results report the document they ran in" || bad "document stamp" "$R"

L="$(tool ai_create '{"kind":"rect","x":0,"y":0,"width":400,"height":300,"fill":"#ff0000","name":"locked bg"}')"
LU="$(echo "$L" | field "['uuid']")"
tool ai_set "{\"writes\":[{\"uuid\":\"$LU\",\"locked\":true}]}" >/dev/null
S="$(tool ai_create '{"kind":"ellipse","x":150,"y":100,"width":60,"height":60,"fill":"#00ff00"}')"
SU="$(echo "$S" | field "['uuid']")"
R="$(tool ai_capture "{\"command\":\"item\",\"uuid\":\"$SU\"}")"
[ "$(echo "$R" | field "['isolated']")" = "True" ] && ! echo "$R" | grep -q couldNotHide \
  && ok "isolated capture hides locked background art" || bad "isolated capture locked" "$R"
R="$(tool ai_query "{\"command\":\"item\",\"uuid\":\"$LU\"}")"
[ "$(echo "$R" | field "['locked']")" = "True" ] && [ "$(echo "$R" | field "['hidden']")" = "False" ] \
  && ok "the locked item is restored locked and visible" || bad "isolated capture restore" "$R"
tool ai_set "{\"writes\":[{\"uuid\":\"$LU\",\"locked\":false}]}" >/dev/null

T1="$(tool ai_create '{"kind":"text","x":40,"y":260,"contents":"not a mask"}')"
T1U="$(echo "$T1" | field "['uuid']")"
R="$(tool ai_items "{\"command\":\"clip\",\"uuids\":[\"$T1U\",\"$SU\"]}")"
P="$(tool ai_query "{\"command\":\"item\",\"uuid\":\"$SU\"}")"
echo "$R" | grep -q "must be a path" && [ "$(echo "$P" | field "['parentUuid']")" = "None" ] \
  && ok "clip with a bad mask changes nothing" || bad "clip bad mask" "$R / $P"

PA="$(tool ai_create '{"kind":"path","points":[[10,10],[60,10],[35,50]],"fill":"#0000ff"}')"
PU="$(echo "$PA" | field "['uuid']")"
R="$(tool ai_set "{\"writes\":[{\"uuid\":\"$PU\",\"points\":[[0,0],[\"x\",5],[9,9]]}]}")"
Q="$(tool ai_query "{\"command\":\"item\",\"uuid\":\"$PU\"}")"
[ "$(echo "$Q" | field "['path']['points']")" = "3" ] && echo "$R" | grep -q "bad_value" \
  && ok "a bad point is refused and the path is left intact" || bad "points validation" "set: $R / item: $Q"
R="$(tool ai_set "{\"writes\":[{\"uuid\":\"$PU\",\"closed\":false}]}")"
Q="$(tool ai_query "{\"command\":\"item\",\"uuid\":\"$PU\"}")"
[ "$(echo "$Q" | field "['path']['closed']")" = "False" ] \
  && ok "closed:false on its own opens the path" || bad "closed alone" "set: $R / item: $Q"
BEFORE="$(tool ai_query '{"command":"find","type":"PathItem"}' | field "['count']")"
R="$(tool ai_create '{"kind":"path","points":[[0,0],[5,5],{"anchor":"bad"}]}')"
AFTER="$(tool ai_query '{"command":"find","type":"PathItem"}' | field "['count']")"
[ "$BEFORE" = "$AFTER" ] && echo "$R" | grep -q "point 2" \
  && ok "a create with a bad point leaves nothing behind" || bad "create cleanup" "$R ($BEFORE -> $AFTER)"

R="$(tool ai_diagnostics '{}')"
echo "$R" | grep -q 'overflowingText' && ok "ai_diagnostics" || bad "ai_diagnostics" "$R"

# Close the scratch document BY NAME, never "whatever is active": the user may
# have clicked into their own file while this ran, and discardUnsaved would
# then throw away their work.
R="$(tool ai_document "{\"command\":\"close\",\"name\":\"$DOC\",\"discardUnsaved\":true}")"
[ "$(echo "$R" | field "['closed']")" = "$DOC" ] && ok "scratch document $DOC closed by name, without saving" \
  || bad "close scratch document by name" "$R"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
