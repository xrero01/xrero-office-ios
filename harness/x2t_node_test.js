// x2t_node_test.js - round-trip the QA documents through x2t WebAssembly: file -> Editor.bin -> same format.
// usage: node x2t_node_test.js   (writes harness/out/x2t/*)
const fs = require('fs'), path = require('path');
const V20 = path.resolve(__dirname, '..', '..');
const IN = path.join(V20, 'release-20.0.9', 'qa', 'inputs');
const OUT = path.join(__dirname, 'out', 'x2t'); fs.mkdirSync(OUT, { recursive: true });
const x2t = require(path.join(V20, 'ios', 'vendor', 'x2t-wasm', 'x2t.js'));

function rmr(p) {
  if (!x2t.FS.analyzePath(p).exists) return;
  if (x2t.FS.isDir(x2t.FS.stat(p).mode)) {
    x2t.FS.readdir(p).filter(e => e !== '.' && e !== '..').forEach(e => rmr(p + '/' + e));
    if (p !== '/') x2t.FS.rmdir(p);
  } else x2t.FS.unlink(p);
}
function run(from, to) {
  const xml = '<?xml version="1.0" encoding="utf-8"?><TaskQueueDataConvert>'
    + '<m_sFileFrom>' + from + '</m_sFileFrom><m_sFileTo>' + to + '</m_sFileTo>'
    + '<m_sFontDir>/working/fonts/</m_sFontDir><m_sThemeDir>/working/themes</m_sThemeDir>'
    + '<m_bIsNoBase64>true</m_bIsNoBase64></TaskQueueDataConvert>';
  x2t.FS.writeFile('/working/params.xml', xml);
  const t = Date.now();
  const rc = x2t.ccall('main1', 'number', ['string'], ['/working/params.xml']);
  return { rc, ms: Date.now() - t };
}
x2t.onRuntimeInitialized = function () {
  const res = {};
  for (const f of fs.readdirSync(IN)) {
    const ext = path.extname(f).slice(1);
    if (!/^(docx|xlsx|pptx)$/.test(ext)) continue;
    rmr('/working'); ['/working', '/working/media', '/working/fonts', '/working/themes'].forEach(d => { try { x2t.FS.mkdir(d); } catch (e) {} });
    x2t.FS.writeFile('/working/' + f, fs.readFileSync(path.join(IN, f)));
    const a = run('/working/' + f, '/working/Editor.bin');
    const bin = x2t.FS.analyzePath('/working/Editor.bin').exists ? x2t.FS.readFile('/working/Editor.bin') : null;
    const media = x2t.FS.analyzePath('/working/media').exists ? x2t.FS.readdir('/working/media').filter(e => e[0] !== '.') : [];
    const back = '/working/back.' + ext;
    const b = bin ? run('/working/Editor.bin', back) : { rc: 'skip' };
    const out = x2t.FS.analyzePath(back).exists ? x2t.FS.readFile(back) : null;
    if (out) fs.writeFileSync(path.join(OUT, 'roundtrip-' + f), out);
    res[f] = { toBin: a, binBytes: bin && bin.length, binHead: bin && Buffer.from(bin.slice(0, 12)).toString('latin1'), media, back: b, outBytes: out && out.length };
    console.log(f, JSON.stringify(res[f]));
  }
  fs.writeFileSync(path.join(OUT, 'result.json'), JSON.stringify(res, null, 1));
};
