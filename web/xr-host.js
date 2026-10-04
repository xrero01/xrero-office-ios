/* xr-host.js - Xrero Office on iPhone / iPad / Mac (Designed for iPad).
 *
 * Runs the Xrero desktop web editors (the same web-apps + sdkjs as Windows/macOS) without the desktop's native
 * shell and without a server: files are converted on the device by ONLYOFFICE x2t compiled to WebAssembly
 * (x2t-worker.js), exactly the converter the desktop runs natively (.docx/.xlsx/.pptx <-> Editor.bin).
 *
 * Injected at document start into every frame (WKUserScript forMainFrameOnly:false; the browser harness injects
 * it into the HTML). It provides window.AscDesktopEditor - the object the desktop shell normally injects - and
 * talks to the host through window.XreroHost:
 *     XreroHost.openFile()             -> Promise<{name, data: ArrayBuffer}>   document to edit
 *     XreroHost.saveFile(name, bytes)  -> Promise<void>                         write it back
 *     XreroHost.putMedia(name, bytes)  -> Promise<void>   XreroHost.mediaUrl(name) -> string   document pictures
 *     XreroHost.x2tBase                -> string                                folder of x2t.js/x2t.wasm/x2t-worker.js
 *     XreroHost.fontUrl(id) / fontsSprite(scale) -> string                      fonts + font-picker previews
 *     XreroHost.pickFile(filter)       -> Promise<{name, data}|null>            picture picker (optional)
 *     XreroHost.command(cmd, param), XreroHost.log(msg), XreroHost.lang, XreroHost.theme
 */
(function () {
  'use strict';
  if (window.AscDesktopEditor) return;
  var H = window.XreroHost || (window.parent && window.parent !== window && window.parent.XreroHost) || null;
  if (!H) { console.warn('[xr-host] no XreroHost'); return; }
  window.XreroHost = H;

  var log = function () { try { H.log && H.log([].slice.call(arguments).join(' ')); } catch (e) {} };
  var noop = function () {};
  var DOC_URL = '/xr-doc';                    // the engine turns it into file:///xr-doc (+ /media/<name>)
  var MEDIA_PREFIX = 'file://' + DOC_URL + '/media/';
  var opened = null;                          // {name, ext, bin: ArrayBuffer}
  var media = {};                             // name -> ArrayBuffer (document pictures, for saving)
  var picked = {};                            // "xr-pick:<n>" -> {name, data}
  var pickSeq = 0;

  window.RendererProcessVariable = {          // theme / direction the desktop shell normally passes in
    theme: { id: H.theme === 'dark' ? 'theme-dark' : 'theme-light', type: H.theme === 'dark' ? 'dark' : 'light', system: H.theme === 'dark' ? 'dark' : 'light' },
    localthemes: {},
    rtl: H.lang === 'ar'
  };

  function editor() { return (window.Asc && window.Asc.editor) || window.editor; }
  function ext(name) { var m = /\.([A-Za-z0-9]+)$/.exec(name || ''); return m ? m[1].toLowerCase() : 'docx'; }

  // ---------------------------------------------------------------- x2t (WebAssembly) in a worker
  var worker = null, seq = 0, waiting = {};
  function x2t(name, data, to, mediaList) {
    if (!worker) {
      worker = new Worker(H.x2tBase + 'x2t-worker.js?base=' + encodeURIComponent(H.x2tBase));
      worker.onmessage = function (e) { var w = waiting[e.data.id]; delete waiting[e.data.id]; w && (e.data.ok ? w.ok(e.data) : w.fail(new Error(e.data.error))); };
      worker.onerror = function (e) { log('x2t worker error', e.message); };
    }
    return new Promise(function (ok, fail) {
      var id = ++seq; waiting[id] = { ok: ok, fail: fail };
      worker.postMessage({ id: id, name: name, data: data, to: to, media: mediaList || [] });
    });
  }

  var A = {
    // ---- identity / capabilities
    IsLocalFile: function () { return true; },
    IsFilePrinting: function () { return false; },
    isSupportPlugins: function () { return false; },
    isSupportMacroses: function () { return false; },
    isSupportNetworkFunctionality: function () { return false; },
    isBlockchainSupport: function () { return false; },
    IsSignaturesSupport: function () { return false; },
    IsProtectionSupport: function () { return false; },
    IsSupportMedia: function () { return false; },
    CryptoMode: 0,
    getEngineVersion: function () { return 0; },
    GetSupportedScaleValues: function () { return [1, 1.25, 1.5, 1.75, 2]; },
    getViewportSettings: function () { return '{}'; },
    GetInstallPlugins: function () { return JSON.stringify([{ url: '', pluginsData: [] }, { url: '', pluginsData: [] }]); },  // [system, user]
    GetFontThumbnailHeight: function () { return 28; },
    getDictionariesPath: function () { return ''; },
    CheckUserId: function () { return 'xr-ios'; },
    CreateEditorApi: function (api) {
      window.__xrApi = api;
      var send = api.sendEvent;           // report engine errors to the host log (with where they came from)
      api.sendEvent = function (name) {
        if (name === 'asc_onError') log('engine error id=' + arguments[1] + ' level=' + arguments[2] + ' @ ' + (new Error().stack || '').split('\n').slice(2, 6).join(' <- ').replace(/https?:\/\/[^ )]*\//g, ''));
        return send.apply(this, arguments);
      };
    },
    GetEncryptedHeader: function () { return 'ENCRYPTED;'; },
    getFontsSprite: function (scale) { return H.fontsSprite ? H.fontsSprite(scale || '') : ''; },
    CheckNeedWheel: function () { return false; },
    features: {},

    // ---- open: host bytes -> x2t -> Editor.bin (+ pictures) -> engine, the way the desktop does it
    LocalStartOpen: function () {
      var name;
      H.openFile().then(function (f) {
        name = f.name;
        log('open', name, f.data.byteLength, 'bytes');
        return x2t(name, f.data, 'Editor.bin');
      }).then(function (r) {
        log('converted to Editor.bin', r.data.byteLength, 'bytes,', r.media.length, 'pictures,', r.ms, 'ms');
        opened = { name: name, ext: ext(name), bin: r.data };
        return Promise.all(r.media.map(function (m) { media[m.name] = m.data; return H.putMedia(m.name, m.data); }));
      }).then(function () {
        window.DesktopOfflineAppDocumentEndLoad(DOC_URL, 'binary_content://xr-open', opened.bin.byteLength);
      }).catch(function (e) {
        log('open failed', e && e.message || e);
        window.DesktopOfflineAppDocumentEndLoad(DOC_URL, '', 0);
      });
    },
    GetOpenedFile: function () { return opened ? opened.bin : null; },
    LocalFileGetSourcePath: function () { return ''; },
    LocalFileGetSaved: function () { return true; },
    LocalFileGetOpenChangesCount: function () { return 0; },
    LocalFileRecovers: function () { return '[]'; },
    LocalFileRecents: function () { return '[]'; },
    IsLocalFileExist: function () { return false; },
    SetDocumentName: function (n) { H.command && H.command('title', n); },
    SetLocalRestrictions: noop,
    SetAdvancedOptions: noop,
    onDocumentModifiedChanged: function (m) { H.command && H.command('modified', m ? '1' : '0'); },
    onDocumentContentReady: function () { H.command && H.command('ready', ''); },
    LocalFileSaveChanges: noop,
    OnSave: noop,                         // 'save round finished' notice for the desktop shell
    AddChanges: noop,

    // ---- save: engine -> Editor.bin -> x2t -> original format -> host
    LocalFileSave: function (param, password, docinfo, fileType) {
      var ed = editor();
      var done = function (err) { try { window.DesktopOfflineAppDocumentEndSave(err, '', ''); } catch (e) { log('endsave', e); } };
      if (!ed || !opened) { log('save: nothing open'); return done(2); }
      var t0 = Date.now(), bin;
      try {
        // the engine's Editor.bin; in a web page it comes base64-encoded and already carries its "DOCY;v10;0;" header
        var file = ed.asc_nativeGetFile3(), d = file.data;
        if (typeof d === 'string') {
          var raw = atob(d); bin = new Uint8Array(raw.length);
          for (var i = 0; i < raw.length; i++) bin[i] = raw.charCodeAt(i);
        } else bin = d;
        if (!/^(DOCY|XLSY|PPTY|VSDY);/.test(String.fromCharCode.apply(null, bin.subarray(0, 5)))) {
          var h = new TextEncoder().encode(file.header), b2 = new Uint8Array(h.length + bin.length);
          b2.set(h, 0); b2.set(bin, h.length); bin = b2;
        }
      } catch (e) { log('save: serialize failed', e); return done(2); }
      var list = Object.keys(media).map(function (n) { return { name: n, data: media[n].slice(0) }; });
      x2t('Editor.bin', bin.buffer, 'out.' + opened.ext, list).then(function (r) {
        return H.saveFile(opened.name, r.data).then(function () {
          log('saved', opened.name, r.data.byteLength, 'bytes in', Date.now() - t0, 'ms');
          done(0);
        });
      }).catch(function (e) { log('save failed', e && e.message || e); done(2); });
    },

    // ---- pictures: picked by the user -> stored as document media
    OpenFilenameDialog: function (filter, multi, cb) {
      if (!H.pickFile) return cb('');
      H.pickFile(filter).then(function (f) {
        if (!f) return cb('');
        var key = 'xr-pick:' + (++pickSeq); picked[key] = f; cb(key);
      }, function () { cb(''); });
    },
    LocalFileGetImageUrl: function (path) {               // returns the media name the engine records
      var f = picked[path];
      if (!f) return path;
      var n = 'image_xr' + Date.now().toString(36) + pickSeq + '.' + ext(f.name);
      media[n] = f.data; H.putMedia(n, f.data);
      delete picked[path];
      return n;
    },
    LocalFileGetImageUrlCorrect: function (url) { return url; },
    GetImageBase64: function () { return ''; },
    GetImageOriginalSize: function () { return { W: 0, H: 0 }; },
    GetImageFormat: function () { return 0; },
    IsImageFile: function (p) { return /\.(png|jpe?g|gif|bmp|webp|heic)$/i.test(p || ''); },
    GetDropFiles: function () { return []; },

    // ---- UI plumbing the desktop shell answers
    execCommand: function (cmd, param) {
      if (cmd === 'editor:event') {
        try { var o = JSON.parse(param); if (o.action === 'file:close') return H.command && H.command('close', ''); } catch (e) {}
      }
      if (cmd === 'go:folder' || (cmd === 'title:button' && /"home"/.test(param || ''))) return H.command && H.command('close', '');
      H.command && H.command(cmd, param || '');
    },
    sendSystemMessage: noop,
    CallInAllWindows: noop,
    SpellCheck: noop,
    Print: noop, Print_Start: noop, Print_Page: noop, Print_End: noop,
    DownloadFiles: noop,
    MediaStart: noop, CallMediaPlayerCommand: noop,
    SaveQuestion: function () { return 0; },
    LoadJS: function () { return 2; },
    RemoveFile: noop,
    PreloadCryptoImage: noop,
    buildCryptedStart: noop, buildCryptedEnd: noop,
    convertFile: noop,
    startExternalConvertation: noop,
    openExternalReference: noop
  };

  // Unknown members: log once so the harness shows what else the editors ask for.
  var seen = {};
  window.AscDesktopEditor = (typeof Proxy === 'function') ? new Proxy(A, {
    get: function (t, k) {
      if (k in t) return t[k];
      if (typeof k === 'string' && !seen[k]) { seen[k] = 1; log('missing AscDesktopEditor.' + k); }
      return undefined;
    }
  }) : A;

  // ---------------------------------------------------------------- engine patches (re-applied while it loads:
  // the local-mode module installs its own versions after the base ones)
  function patchEngine() {
    // fonts: the desktop loads "ascdesktop://fonts/<id>"; the host maps ids to its bundled files
    if (window.AscFonts && AscFonts.CFontFileLoader) {
      var P = AscFonts.CFontFileLoader.prototype;
      if (!(P.LoadFontAsync && P.LoadFontAsync.__xr)) {
        P.LoadFontAsync = function (basePath, callback) {
          this.callback = callback;
          if (-1 !== this.Status) return true;
          this.Status = 2;
          var self = this;
          fetch(H.fontUrl(this.Id)).then(function (r) { if (!r.ok) throw r.status; return r.arrayBuffer(); }).then(function (buf) {
            self.Status = 0;
            var streams = AscFonts.g_fonts_streams, i = streams.length, d = new Uint8Array(buf);
            streams[i] = new AscFonts.FontStream(d, d.length);
            self.SetStreamIndex(i);
            self.callback && self.callback();
            self["externalCallback"] && self["externalCallback"]();
          }).catch(function (e) { self.Status = 1; log('font failed', self.Id, e); });
        };
        P.LoadFontAsync.__xr = true;
        P['LoadFontAsync'] = P.LoadFontAsync;
      }
    }
    // pictures: file:///xr-doc/media/<name>  <->  host media URL
    if (window.AscCommon && AscCommon.DocumentUrls) {
      var D = AscCommon.DocumentUrls.prototype;
      var out = function (u) { return (typeof u === 'string' && u.indexOf(MEDIA_PREFIX) === 0) ? H.mediaUrl(u.substring(MEDIA_PREFIX.length)) : u; };
      ['getImageUrl', 'getUrl'].forEach(function (fn) {
        var orig = D[fn];
        if (!orig || orig.__xr) return;
        D[fn] = function () { return out(orig.apply(this, arguments)); };
        D[fn].__xr = true;
      });
      var origLocal = D.getImageLocal;
      if (origLocal && !origLocal.__xr) {
        D.getImageLocal = function (url) {
          var base = H.mediaUrl('');
          if (typeof url === 'string' && url.indexOf(base) === 0) return decodeURIComponent(url.substring(base.length));
          return origLocal.apply(this, arguments);
        };
        D.getImageLocal.__xr = true;
      }
    }
  }
  var tries = 0, timer = setInterval(function () { patchEngine(); if (++tries > 2400) clearInterval(timer); }, 25);

  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    log('unhandled rejection: ' + String(r && (r.stack || r.message) || r).slice(0, 400));
  });
  window.addEventListener('error', function (e) { log('error: ' + (e.message || '') + ' @ ' + (e.filename || '').split('/').pop() + ':' + e.lineno); });

  log('xr-host ready in', location.pathname.split('/').slice(-3).join('/'));
})();
