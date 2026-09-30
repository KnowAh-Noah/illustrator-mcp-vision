/*
 * Vision ops.
 *
 * Document.imageCapture renders any rectangle of the document to a PNG at a
 * chosen resolution - including the pasteboard, which exportFile cannot. It
 * is also far faster: measured on 30.8.1, 129ms for an 800x600 artboard
 * against 1084ms for exportFile PNG24. Resolution is the cost lever: 72 ppi is
 * one pixel per point, so the resolution is picked to land the long edge on
 * the size asked for - never below 72, the floor imageCapture accepts.
 */

function __mcp_captureRect(doc, bounds, fileName, longEdge) {
    var file = __mcp_safeCaptureFile(fileName);
    var w = bounds[2] - bounds[0], h = bounds[1] - bounds[3];
    if (w <= 0 || h <= 0) { throw new Error("Nothing to capture: the region is " + w + " x " + h + "pt"); }
    var ppi = 72 * Number(longEdge) / Math.max(w, h);
    // imageCapture refuses anything below 72 ppi - measured: "Specified value
    // less than minimum allowed value" at 71. A large artboard is rendered at
    // 72 and the Node side scales it down to longEdge.
    ppi = Math.max(72, Math.min(2400, ppi));

    var o = new ImageCaptureOptions();
    o.resolution = ppi;
    o.antiAliasing = true;
    o.transparency = true;

    var t0 = new Date().getTime();
    doc.imageCapture(file, bounds, o);
    if (!file.exists) { throw new Error("imageCapture produced no file"); }
    return {
        path: file.fsName, fileName: fileName,
        width: Math.round(w * ppi / 72), height: Math.round(h * ppi / 72),
        resolution: __mcp_round(ppi), ms: new Date().getTime() - t0
    };
}

function __mcp_padBounds(b, pad) {
    return [b[0] - pad, b[1] + pad, b[2] + pad, b[3] - pad];
}

/* True when a is b or sits anywhere inside b. */
function __mcp_isWithin(a, b) {
    var node = a;
    while (node && node.typename !== "Layer" && node.typename !== "Document") {
        if (node === b) { return true; }
        node = node.parent;
    }
    return false;
}

var __mcp_captureOps = {

    captureArtboard: function (args) {
        var doc = __mcp_doc();
        var ab = __mcp_artboardIndex(doc, args.artboard);
        var r = doc.artboards[ab].artboardRect;
        var out = __mcp_captureRect(doc, r, args.fileName, args.longEdge || 768);
        out.artboard = ab; out.artboardName = doc.artboards[ab].name;
        return out;
    },

    /* A rectangle in artboard space - for looking at one corner closely. */
    captureRegion: function (args) {
        var doc = __mcp_doc();
        var ab = __mcp_artboardIndex(doc, args.artboard);
        if (!__mcp_has(args.width) || !__mcp_has(args.height)) { throw new Error("region needs x, y, width, height"); }
        var b = __mcp_boundsFromBox(doc, ab, { x: args.x || 0, y: args.y || 0, width: args.width, height: args.height });
        var out = __mcp_captureRect(doc, b, args.fileName, args.longEdge || 768);
        out.artboard = ab;
        return out;
    },

    /*
     * One item, cropped to its visible bounds plus padding. isolated (default
     * true) hides everything else for the capture, which separates "drawn but
     * covered by something" from "not drawn at all". Hidden flags are
     * recorded and restored exactly, and the whole op is one undo step.
     */
    captureItem: function (args) {
        var doc = __mcp_doc();
        var it = __mcp_item(args.uuid);
        var pad = __mcp_has(args.padding) ? Number(args.padding) : 8;
        var bounds = __mcp_padBounds(it.visibleBounds, pad);
        var isolated = args.isolated !== false;
        var hiddenNow = [], layersShown = [];

        try {
            if (isolated) {
                var all = doc.pageItems;
                for (var i = 0; i < all.length; i++) {
                    var p = all[i];
                    // Keep the target, its ancestors and its descendants.
                    if (__mcp_isWithin(it, p) || __mcp_isWithin(p, it)) { continue; }
                    if (!p.hidden) {
                        try { p.hidden = true; hiddenNow.push(p); } catch (e) { /* locked: leave it */ }
                    }
                }
                // An item on a hidden layer renders nothing even when isolated.
                var l = it.layer;
                while (l && l.typename === "Layer") {
                    if (!l.visible) { l.visible = true; layersShown.push(l); }
                    l = l.parent;
                }
            }
            var out = __mcp_captureRect(doc, bounds, args.fileName, args.longEdge || 512);
            out.uuid = it.uuid; out.type = it.typename; out.isolated = isolated;
            out.hiddenForCapture = hiddenNow.length;
            return out;
        } finally {
            for (var j = 0; j < hiddenNow.length; j++) { try { hiddenNow[j].hidden = false; } catch (e) {} }
            for (var k = 0; k < layersShown.length; k++) { try { layersShown[k].visible = false; } catch (e) {} }
        }
    }
};
