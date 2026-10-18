/* x2t-worker.js - ONLYOFFICE x2t (WebAssembly build) in a Web Worker: converts between Office files and the
   editors' internal format (Editor.bin), on the device, without a server.
   new Worker('x2t-worker.js?base=<url of folder holding x2t.js + x2t.wasm>')
   request : {id, name, data: ArrayBuffer, to: 'Editor.bin'|'out.docx'|..., media: [{name, data}],
              changes: [{name, data}], fromChanges: bool, fonts: [url]}
             PDF editing: name 'origin.pdf' + to 'out.pdf' + fromChanges + changes [the PDF editor's compiled changes,
             starting with "%PDF"] -> x2t opens the original in edit mode (EditPdf) and applies them
             (AddToPdfFromBinary); fonts = the font files the edits may need (loaded once, kept in /fonts)
   reply   : {id, ok: true, data: ArrayBuffer, media: [{name, data}], ms} | {id, ok: false, error} */
'use strict';
var base = (new URLSearchParams(self.location.search)).get('base') || './';
var ready = new Promise(function (resolve, reject) {
  self.Module = {
    locateFile: function (p) { return base + p; },
    onRuntimeInitialized: resolve,
    onAbort: reject,
    print: function () {},
    printErr: function () {}
  };
});
importScripts(base + 'x2t.js');
// x2t stamps files with getenv("APPLICATION_NAME") (default "ONLYOFFICE"); x2t.js's ENV is a worker global and
// is read once, when the converter first starts - so set it before the WebAssembly finishes loading
if (typeof ENV === 'object') ENV.APPLICATION_NAME = 'Xrero Office';

function rmr(p) {
  var FS = Module.FS;
  if (!FS.analyzePath(p).exists) return;
  if (FS.isDir(FS.stat(p).mode)) {
    FS.readdir(p).forEach(function (e) { if (e !== '.' && e !== '..') rmr(p + '/' + e); });
    FS.rmdir(p);
  } else FS.unlink(p);
}

// fonts for conversions that draw text (PDF editing): fetched once per worker, kept in /fonts
var fontsLoaded = null;
function loadFonts(urls) {
  if (!urls || !urls.length) return Promise.resolve(false);
  if (fontsLoaded) return fontsLoaded;
  fontsLoaded = ready.then(function () {
    var FS = Module.FS;
    if (!FS.analyzePath('/fonts').exists) FS.mkdir('/fonts');
    return Promise.all(urls.map(function (u, i) {
      return fetch(u).then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
        .then(function (b) { FS.writeFile('/fonts/f' + i + '.ttf', new Uint8Array(b)); return 1; })
        .catch(function () { return 0; });
    }));
  }).then(function (got) { return got.reduce(function (a, b) { return a + b; }, 0) > 0; });
  return fontsLoaded;
}

self.onmessage = function (e) {
  var q = e.data;
  Promise.all([ready, loadFonts(q.fonts)]).then(function (r) {
    var FS = Module.FS, t0 = Date.now(), fontDir = r[1] ? '/fonts/' : '/working/fonts/';
    rmr('/working');
    ['/working', '/working/media', '/working/fonts', '/working/themes', '/working/changes'].forEach(function (d) { FS.mkdir(d); });
    FS.writeFile('/working/' + q.name, new Uint8Array(q.data));
    (q.media || []).forEach(function (m) { FS.writeFile('/working/media/' + m.name, new Uint8Array(m.data)); });
    (q.changes || []).forEach(function (c) { FS.writeFile('/working/changes/' + c.name, new Uint8Array(c.data)); });
    FS.writeFile('/working/params.xml',
      '<?xml version="1.0" encoding="utf-8"?><TaskQueueDataConvert>' +
      '<m_sFileFrom>/working/' + q.name + '</m_sFileFrom><m_sFileTo>/working/' + q.to + '</m_sFileTo>' +
      '<m_sFontDir>' + fontDir + '</m_sFontDir><m_sThemeDir>/working/themes</m_sThemeDir>' +
      (q.fromChanges ? '<m_bFromChanges>true</m_bFromChanges>' : '') +
      '<m_bIsNoBase64>true</m_bIsNoBase64></TaskQueueDataConvert>');
    var rc = Module.ccall('main1', 'number', ['string'], ['/working/params.xml']);
    if (rc !== 0 || !FS.analyzePath('/working/' + q.to).exists) throw new Error('x2t exit code ' + rc);
    var out = FS.readFile('/working/' + q.to);
    var media = [], transfer = [out.buffer];
    if (q.to === 'Editor.bin') {
      FS.readdir('/working/media').forEach(function (n) {
        if (n === '.' || n === '..') return;
        var d = FS.readFile('/working/media/' + n);
        media.push({ name: n, data: d.buffer }); transfer.push(d.buffer);
      });
    }
    self.postMessage({ id: q.id, ok: true, data: out.buffer, media: media, ms: Date.now() - t0 }, transfer);
  }).catch(function (err) {
    self.postMessage({ id: q.id, ok: false, error: String(err && err.message || err) });
  });
};
