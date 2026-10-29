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

  // Theme / direction the desktop shell normally passes in. 20.3 (M6): "same as system" - the engine resolves it to its
  // modern light / dark themes (theme-white / theme-night: neutral chrome, line tabs, modern icons) and follows iOS
  // live: the app sends 'renderervars:changed' when the appearance changes (EditorWebView), no reload. In desktop mode
  // customization.uiTheme is ignored; desktopinit copies THIS object into window.uitheme. Colours: neutralChrome below.
  var SYS = H.theme === 'dark' ? 'dark' : 'light';
  window.RendererProcessVariable = {
    theme: { id: 'theme-system', type: SYS, system: SYS },
    localthemes: {},
    rtl: H.lang === 'ar'
  };
  try {
    // the live switch (Themes.refreshTheme) only acts when a theme id is stored; a theme picked earlier in the
    // editor's own settings would otherwise win over iOS. The cached colours of the old theme go too.
    localStorage.setItem('ui-theme-id', 'theme-system');
    localStorage.removeItem('ui-theme');
  } catch (e) {}

  // Xrero header controls that need the Windows shell (account, PDF->Word converter, Designs): not on this platform.
  // EN/AR and Share stay: the app handles 'xrero:lang:<code>' and 'xrero:share'.
  // iPad (and Mac "Designed for iPad" with touch): touch-sized rows, the full ribbon
  var TABLET = Math.min(screen.width, screen.height) >= 600 &&
    ((navigator.maxTouchPoints || 0) > 1 || /xrtouch/.test((function () { try { return top.location.search; } catch (e) { return ''; } })()));

  // portrait (or narrow) iPads: the settings panel on the right takes a third of the width - start every document
  // with it closed (the editors remember "closed by the user" per editor; the panel's side button still opens it).
  // Orientation, not a width: the 13-inch iPad Pro is 1032 pt wide in PORTRAIT, so the old "< 1000" kept it open.
  // Same rule as hideRightMenu in xr-editor.html.
  var narrowWindow = function () { return window.innerWidth < window.innerHeight || window.innerWidth < 1100; };
  if (TABLET && narrowWindow()) {
    try { ['de', 'pe', 'sse', 'pdfe'].forEach(function (p) { localStorage.setItem(p + '-hide-right-settings', 'true'); }); } catch (e) {}
  }
  // ...and when the window turns portrait / narrow later (rotation, Split View), close it again through the panel's
  // own button (the editor's controller then keeps its state and the remembered setting in step). Only on a WIDTH
  // change: the keyboard changes the height alone, and a panel the user opened must not shut while they type.
  if (TABLET) {
    var lastW = window.innerWidth, rmTimer = 0;
    window.addEventListener('resize', function () {
      clearTimeout(rmTimer);
      rmTimer = setTimeout(function () {
        var w = window.innerWidth;
        if (w === lastW) return;
        lastW = w;
        if (!narrowWindow()) return;
        closeRightPanel();
      }, 300);
    });
  }
  // Collapse the right settings panel to its button column through the editor's RightMenu controller (the same
  // clearSelection the editors call themselves) and remember it like a user's close. Fallback: the active side button.
  function closeRightPanel() {
    var btn = document.querySelector('#right-menu .btn.active');      // only the editor frame has the panel
    if (!btn || !btn.offsetParent) return;                            // already closed / not an editor frame
    var apps = { de: window.DE, pe: window.PE, sse: window.SSE, pdfe: window.PDFE };
    for (var p in apps) {
      var ctl = null;
      try { ctl = apps[p] && apps[p].getController && apps[p].getController('RightMenu'); } catch (e) {}
      if (ctl && ctl.rightmenu && ctl.rightmenu.clearSelection) {
        try {
          ctl.rightmenu.clearSelection();
          Common.localStorage.setItem(p + '-hide-right-settings', 1);
          Common.Utils.InternalSettings.set(p + '-hide-right-settings', true);
          return;
        } catch (e) { log('right panel', e); }
      }
    }
    try { btn.click(); } catch (e) { log('right panel', e); }
  }

  // 20.2: earlier versions stored a zoom the editors read before the configured one (de-/pe-/pdfe-/sse- settings-zoom
  // and last-zoom) - clear them once so the corrected default (fit width / fit slide) reaches existing users
  try {
    if (!localStorage.getItem('xr-mig-202-zoom')) {
      ['de', 'pe', 'pdfe', 'sse'].forEach(function (p) {
        localStorage.removeItem(p + '-settings-zoom'); localStorage.removeItem(p + '-last-zoom');
      });
      localStorage.setItem('xr-mig-202-zoom', '1');
    }
  } catch (e) {}

  // Save As / Download As (File menu format tiles, Ctrl+Shift+S): a COPY in a format the user picks, handed to the
  // share sheet; the original file is never touched. Only formats the on-device converter writes correctly are offered - checked by
  // converting the EN + AR store samples to each one and back (all text kept; OOXML templates get their own content
  // type only when x2t is told the format code). Left out on purpose: PDF / PDF/A / pictures / HTML / EPUB / FB2 / MD
  // (x2t-wasm cannot write them yet), TXT and CSV (this WebAssembly build writes Arabic as broken single bytes), ODS /
  // OTS (its writer drops header cells). Codes = Asc.c_oAscFileType = x2t's AVS_OFFICESTUDIO_FILE_* values.
  var SAVE_AS = {
    documenteditor: [['docx', 0x41], ['dotx', 0x4c], ['odt', 0x43], ['ott', 0x4f], ['rtf', 0x44]],
    spreadsheeteditor: [['xlsx', 0x101], ['xltx', 0x106]],
    presentationeditor: [['pptx', 0x81], ['potx', 0x87], ['ppsx', 0x84], ['odp', 0x83], ['otp', 0x8a]]
  };
  function saveAsFormats() {
    var m = /\/(documenteditor|spreadsheeteditor|presentationeditor)\//.exec(location.pathname);
    return m ? SAVE_AS[m[1]] : [];
  }
  function saveAsTiles() {
    var f = saveAsFormats();
    if (!f.length) return '';
    return '#panel-saveas .format-item:not(:has(' + f.map(function (x) { return '.btn-doc-format[format="' + x[1] + '"]'; }).join(',') +
      ')){display:none!important}';
  }

  (function hideDesktopOnly() {
    // language / share / account are in the app's own top bar on iOS: the editors' header cluster is not needed
    var css = '#xr-b-ctx,#xr-designs-launch,#xr-design-ov,#xr-hdr-btns,#xr-acct-menu{display:none!important}' +
              // File menu: recent files live on the app's home screen; "Suggest a Feature" opens a desktop form
              '#fm-btn-recent,#fm-btn-suggest{display:none!important}' +
              // File menu entries that would do nothing here (each checked in web-apps FileMenu + Desktop.js):
              // Open sends 'editor:event file:open', which the app has no handler for (files open from the home
              // screen); Print / Print preview call AscDesktopEditor.Print, a no-op without a printer bridge (M7b);
              // Spreadsheets' "Export to PDF" asks for a PDF, which the on-device converter cannot write yet
              '#fm-btn-local-open,#fm-btn-print,#fm-btn-print-with-preview,#fm-btn-export-pdf{display:none!important}' +
              // PDFs are saved in place by the PDF editor (savePdf): no "Download As" / "Save As" copy to offer there
              (/pdfeditor/.test(location.pathname) ? '#fm-btn-download,#fm-btn-save-desktop,#panel-saveas{display:none!important}' :
              // "Download As" format tiles: only the formats Save As really writes (SAVE_AS below); the rest are hidden
              saveAsTiles());
    // phones: the status bar keeps what a finger needs (page/slide count, Present, zoom); the text-language picker,
    // spell-check toggle and fit-to-page/width icons go (pinch and the zoom buttons cover fitting)
    if (Math.min(screen.width, screen.height) < 600) {
      // header: 44 pt title row (save / undo / redo / more), 46 pt tabs with 16 pt labels
      css += '#app-title,#box-document-title{height:44px!important}' +
        '#box-document-title .btn{min-width:46px!important;height:40px!important;margin:2px 2px!important;border-radius:10px!important}' +
        '#box-document-title .btn .icon{transform:scale(1.3)}' +
        // the file name is already in the app's top bar
        '#box-document-title #id-box-doc-name,#box-document-title #title-doc-name{display:none!important}' +
        '.toolbar .tabs>ul>li>a,.toolbar .tabs .ribtab>a{font-size:15px!important;line-height:46px!important;height:46px!important;' +
          'padding:0 12px!important}' +
        '.toolbar .box-tabs,.toolbar .tabs{height:46px!important}' +
        '.toolbar .tabs a{outline:none!important}' +
        // the ribbon: a tapped tab drops its panel over the page; on a phone every group of the tab wraps into rows
        // (nothing hidden in an overflow menu, nothing clipped - menus open in full), buttons 1.3x
        '.toolbar .box-controls{zoom:1.3;overflow:visible!important;height:auto!important;display:flex!important;' +
          'flex-wrap:wrap!important;align-items:flex-start;padding-bottom:6px}' +
        '.toolbar .box-controls>.panel.static{display:flex!important;flex-wrap:wrap}' +
        '.toolbar .box-panels{width:100%!important;flex:1 1 100%!important;min-width:0}' +
        '.toolbar .box-panels>.panel.active{display:flex!important;flex-wrap:wrap!important;width:auto!important;' +
          'row-gap:6px;align-items:flex-start}' +
        '.toolbar .box-panels>.panel.active>*{float:none!important}' +
        '.toolbar .box-panels>.panel.active>.separator{display:none!important}' +
        '.toolbar .box-panels .more-box{display:none!important}' +
        '.toolbar .box-panels .group.field-styles{height:54px!important;position:relative!important;min-width:160px}' +
        '.toolbar .box-panels .group.field-styles>.combo-dataview{position:relative!important;top:0!important;left:0!important}' +
        '.toolbar.folded .box-controls{box-shadow:0 8px 20px rgba(0,0,0,.18)}' +
        '.toolbar .tabs .scroll{line-height:46px!important;height:46px!important;background:transparent!important}';
      // phones: an iOS-style bottom bar - 50 pt tall, 44 pt round buttons, the page / slide count as a pill.
      // It keeps what a finger needs (count, Present, previous / next page, zoom - +, sheet tabs); the text-language
      // picker, spell check, word count, track-changes toggle, select / hand tools and fit icons go (their features
      // stay in the ribbon tabs). Set before the editor measures its layout (the status bar height is read once).
      var hide = ['btn-cnt-lang', 'btn-doc-lang', 'btn-doc-spell', 'btn-zoom-topage', 'btn-zoom-towidth', 'status-label-zoom',
                  'label-zoom', 'slot-status-btn-info', 'status-btn-multiple-pages', 'btn-doc-review', 'label-action',
                  'status-btn-select-tool', 'status-btn-hand-tool', 'status-label-action'];
      css += hide.map(function (id) { return '#statusbar #' + id; }).join(',') + '{display:none!important}' +
        'body{--statusbar-height:50px!important}' +
        '#statusbar{height:50px!important;border-top:.5px solid var(--xr-sep,rgba(0,0,0,.12))!important}' +
        '#statusbar>.statusbar{height:50px!important;align-items:center!important;padding:0 10px!important;box-sizing:border-box}' +
        '#statusbar .status-group{display:flex;align-items:center;height:50px!important;gap:6px}' +
        '#statusbar .status-group.cnt-flex-center{justify-content:flex-end;flex:1 1 auto}' +
        '#statusbar .separator{display:none!important}' +
        '#statusbar .btn-toolbar{min-width:44px!important;height:40px!important;border-radius:12px!important;' +
          'align-items:center;justify-content:center;background:rgba(127,127,127,.12)!important}' +
        '#statusbar .btn-toolbar:not([style*="none"]){display:inline-flex}' +
        '#statusbar .btn-toolbar .icon{transform:scale(1.35)}' +
        '#statusbar label{font-size:15px!important;font-weight:600!important;line-height:36px!important;height:36px!important;' +
          'padding:0 14px!important;border-radius:18px;background:rgba(127,127,127,.12);margin:0!important}' +
        // Slides: the Present button as a proper pill
        '#statusbar #slot-status-btn-preview .btn-toolbar{background:transparent!important;min-width:0!important}' +
        '#statusbar #slot-status-btn-preview .dropdown-toggle{display:none!important}' +
        // (a true capsule: 36 pt high, radius 18)
        '#statusbar #slot-status-btn-preview .btn:not(.dropdown-toggle){height:36px!important;border-radius:18px!important;' +
          'padding:0 16px!important;font-size:15px!important;font-weight:600!important}' +
        // Slides fit the screen by themselves: no zoom buttons next to Present and the slide count
        (/presentationeditor/.test(location.pathname) ? '#statusbar #btn-zoom-down,#statusbar #btn-zoom-up{display:none!important}' : '') +
        // Spreadsheets: the sheet tabs need the room (no tab-scroll arrows or zoom; the tabs scroll by swiping)
        (/spreadsheeteditor/.test(location.pathname) ? '#statusbar #status-btn-tabback,#statusbar #status-btn-tabnext,' +
          '#statusbar #status-zoom-box,#statusbar #status-tabs-scroll{display:none!important}' +
          '#statusbar #status-addtabs-box{flex:0 0 auto!important;padding:0 6px 0 0!important}' : '') +
        // PDF: pages change by scrolling; the previous / next arrows make room for zoom
        (/pdfeditor/.test(location.pathname) ? '#statusbar #slot-status-btn-prev,#statusbar #slot-status-btn-next{display:none!important}' : '') +
        // Excel: bigger sheet tabs
        '#statusbar #status-sheets-bar li>span,#statusbar #status-sheets-bar li a{line-height:40px!important;height:40px!important;font-size:15px!important;padding:0 14px!important}';
    } else if (TABLET) {
      // iPad: the full ribbon fits; rows and the status bar get touch-sized (40 pt rows, 50 pt status bar, 44 pt
      // buttons) in the same iOS style
      var SSE = /spreadsheeteditor/.test(location.pathname);
      css += '#app-title,#box-document-title{height:40px!important}' +
        '#box-document-title .btn{min-width:42px!important;height:36px!important;margin:2px!important;border-radius:9px!important}' +
        '#box-document-title .btn .icon{transform:scale(1.2)}' +
        '.toolbar .tabs>ul>li>a,.toolbar .tabs .ribtab>a{font-size:14px!important;line-height:40px!important;height:40px!important;' +
          'padding:0 14px!important}' +
        '.toolbar .box-tabs,.toolbar .tabs{height:40px!important}' +
        '.toolbar .tabs a{outline:none!important}' +
        '.toolbar .tabs .scroll{line-height:40px!important;height:40px!important;background:transparent!important}' +
        '.toolbar .box-controls .btn-toolbar{min-width:30px}' +
        // the ribbon's own height rule is "tabs row + controls row" with the stock 28 / 32 px tabs row (a less constant,
        // not a variable). The 40 pt tabs above took 8-12 px from the controls row, so the bottom of "Edit PDF" and
        // the second row of small icons were cut off: give the box the 40 pt row plus the full controls row
        // (fitRibbon below makes the layout reserve the same height, so nothing lies over the page)
        '.toolbar:not(.folded),.top-title>.toolbar:not(.folded),.toolbar.folded.expanded,.top-title>.toolbar.folded.expanded{' +
          'height:calc(40px + var(--toolbar-height-controls,66px))!important}' +
        '.toolbar.folded:not(.expanded),.top-title>.toolbar.folded:not(.expanded){height:40px!important}' +
        '#statusbar #btn-cnt-lang,#statusbar #btn-doc-lang,#statusbar #btn-doc-spell,#statusbar #btn-zoom-topage,' +
          '#statusbar #btn-zoom-towidth,#statusbar #status-btn-select-tool,#statusbar #status-btn-hand-tool{display:none!important}' +
        // labels the editors leave empty (the "action" label, a blank page counter) drew as empty grey pills
        // (:empty only - the same labels carry real status text, e.g. a save or recalculation message, when set)
        '#statusbar label:empty{display:none!important}' +
        'body{--statusbar-height:50px!important}' +
        '#statusbar{height:50px!important;border-top:.5px solid var(--xr-sep,rgba(0,0,0,.12))!important}' +
        // the iPadOS window-resize corner sits at the bottom RIGHT (in Arabic too): keep 28 pt free there. The bar is
        // made the positioning box so the spreadsheet's absolutely placed zoom / sheet boxes respect that margin.
        '#statusbar>.statusbar{height:50px!important;align-items:center!important;padding:0 12px!important;box-sizing:border-box;' +
          'position:relative;margin-right:28px!important}' +
        '#statusbar .separator{display:none!important}' +
        '#statusbar .btn-toolbar{min-width:44px!important;height:44px!important;border-radius:10px!important;' +
          'align-items:center;justify-content:center}' +
        '#statusbar .btn-toolbar .icon{transform:scale(1.2)}' +
        '#statusbar #slot-status-btn-preview .btn:not(.dropdown-toggle){height:36px!important;border-radius:18px!important;' +
          'padding:0 14px!important;font-size:14px!important;font-weight:600!important}' +
        (!SSE ?
          // Word / Slides / PDF: flex groups, the count pill at the start, zoom at the end
          '#statusbar .status-group{display:flex;align-items:center;height:50px!important;gap:6px}' +
          '#statusbar .status-group.cnt-flex-center{justify-content:flex-end;flex:1 1 auto}' +
          '#statusbar label{font-size:14px!important;font-weight:600!important;line-height:34px!important;height:34px!important;' +
            'padding:0 12px!important;border-radius:17px;background:rgba(127,127,127,.12);margin:0!important}'
        :
          // Spreadsheets lay their status bar out themselves: the sheet tabs sit in an absolutely placed box between
          // the tab buttons and the zoom box, its offsets measured from those boxes' widths. Growing the boxes
          // (flex:1 like the other editors) pushed the tabs to zero width and the zoom box over + / list.
          // So: no flex growth here; the scroll arrows go (tabs scroll by swiping) with a zero width the measurement
          // reads; + and the sheet list are 44 pt; tabs 40 pt with 15 px text and a 2 pt underline on the active one.
          // (a trackpad / mouse keeps the arrows: any-pointer:fine; VoiceOver uses the sheet list button)
          '@media not all and (any-pointer:fine){#statusbar #status-tabs-scroll{display:none!important;width:0!important;padding:0!important}}' +
          '#statusbar #status-addtabs-box{display:flex!important;align-items:center;gap:4px;padding:0 6px!important;flex:0 0 auto!important;' +
            'height:50px!important}' +
          '#statusbar #status-zoom-box{display:flex!important;align-items:center;gap:6px;height:50px!important}' +
          '#statusbar #status-zoom-box .btn-toolbar{margin:0!important}' +
          '#statusbar #status-label-zoom{font-size:14px!important;font-weight:600!important;line-height:34px!important;height:34px!important;' +
            'padding:0 12px!important;border-radius:17px;background:rgba(127,127,127,.12);margin:0!important;display:inline-block}' +
          '#statusbar #status-sheets-bar li>span{font-size:15px!important;line-height:40px!important;height:40px!important;' +
            'margin-top:5px!important;padding-top:0!important;padding-bottom:0!important}' +
          '#statusbar #status-sheets-bar li:not(.icon-visible)>span{padding-left:14px!important;padding-right:14px!important}' +
          '#statusbar #status-sheets-bar li.active>span,#statusbar #status-sheets-bar li.selected>span{' +
            'box-shadow:inset 0 -2px 0 var(--highlight-toolbar-tab-underline-spreadsheet,#1E9E5A)!important}');
    }
    var add = function () {
      if (document.getElementById('xr-host-css')) return;
      var s = document.createElement('style'); s.id = 'xr-host-css'; s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    };
    if (document.documentElement) add();
    document.addEventListener('DOMContentLoaded', add);
  })();

  // 20.3 (M6): neutral, coherent editor chrome on every device. The engine's own modern themes (theme-white /
  // theme-night, picked by "same as system" above) do the layout; this only re-points their colour TOKENS, so every
  // panel, menu and the canvas (asc_setSkin reads the same tokens) stay consistent and a live light/dark switch just
  // swaps the token set - nothing here fights individual elements. Surfaces are the iOS bar colours, no coloured
  // header slab; the kind accent (Xrero's own token file, not Office's hex values) appears only as the active tab's
  // underline; Xrero teal is the primary-button tint; the chrome uses the system font (never the canvas: the page is
  // drawn by sdkjs with the document's fonts). Selectors carry :root + :is(...) so they outrank the theme blocks
  // (":root .theme-white"). Static CSS only - nothing runs while typing.
  (function neutralChrome() {
    var K = ':root body:is(.theme-white,.theme-night)';
    var css =
      // light tokens (labels: iOS label / secondaryLabel; accents >= 3:1 on the bar for the underline; every filled
      // button's label >= 4.5:1 on its fill: white on the tint 5:1 / 6.7:1 (pressed), white on --xr-present 4.6:1;
      // dark mode: BLACK labels on the light tints, 9:1 and more - white there was only 2.3:1)
      ':root body.theme-white{--xr-bar:#F9F9F9;--xr-canvas:#F2F2F7;--xr-label:#000;--xr-label2:rgba(60,60,67,.75);' +
        '--xr-sep:rgba(60,60,67,.29);--xr-tint:#1F7A8C;--xr-tint-hi:#196575;--xr-on-accent:#fff;' +
        '--xr-doc:#2F6BD8;--xr-sheet:#1E9E5A;--xr-slide:#E0612F;--xr-present:#C4502A;--xr-pdf:#C62828}' +
      ':root body.theme-night{--xr-bar:#1C1C1E;--xr-canvas:#000;--xr-label:#fff;--xr-label2:rgba(235,235,245,.7);' +
        '--xr-sep:rgba(84,84,88,.65);--xr-tint:#5CB8C9;--xr-tint-hi:#7ACBD8;--xr-on-accent:#000;' +
        '--xr-doc:#7AA7F0;--xr-sheet:#4CC38A;--xr-slide:#FF8A65;--xr-present:#FF8A65;--xr-pdf:#FF6B6B}' +
      K + '{' +
        ['document', 'spreadsheet', 'presentation', 'pdf', 'visio'].map(function (k) { return '--toolbar-header-' + k + ':var(--xr-bar)!important'; }).join(';') + ';' +
        [['document', 'doc'], ['spreadsheet', 'sheet'], ['presentation', 'slide'], ['pdf', 'pdf'], ['visio', 'doc']].map(function (k) {
          return '--highlight-toolbar-tab-underline-' + k[0] + ':var(--xr-' + k[1] + ')!important;' +
                 '--highlight-header-tab-underline-' + k[0] + ':var(--xr-' + k[1] + ')!important';
        }).join(';') + ';' +
        '--background-toolbar:var(--xr-bar)!important;--background-toolbar-tab:var(--xr-bar)!important;' +
        '--background-statusbar:var(--xr-bar)!important;--border-toolbar-active-panel-top:var(--xr-bar)!important;' +
        '--border-toolbar:var(--xr-sep)!important;--border-divider:var(--xr-sep)!important;' +
        '--text-toolbar-header:var(--xr-label)!important;' +
        '--toolbar-tab-line-height:2.5px!important;--toolbar-tab-line-radius:1.25px!important;' +
        '--canvas-background:var(--xr-canvas)!important;--canvas-content-background:#fff!important;' +
        '--background-primary-dialog-button:var(--xr-tint)!important;--background-accent-button:var(--xr-tint)!important;' +
        '--highlight-primary-dialog-button-hover:var(--xr-tint-hi)!important;--highlight-primary-dialog-button-pressed:var(--xr-tint-hi)!important;' +
        '--border-control-focus:var(--xr-tint)!important;--border-preview-select:var(--xr-tint)!important;' +
        '--font-family-base-custom:-apple-system,system-ui,"SF Arabic","Geeza Pro",sans-serif!important}' +
      // Arabic: the engine sets its own Arabic UI font on .rtl-font[applang=ar] - the same system font there
      ':root .rtl-font[applang]{--font-family-base-custom:-apple-system,system-ui,"SF Arabic","Geeza Pro",sans-serif!important}' +
      // tabs: text labels in the secondary label colour, the active one in the label colour (its underline: the kind
      // accent through the tokens above)
      K + ' .toolbar .tabs .ribtab>a{font-weight:500!important;color:var(--xr-label2)!important}' +
      K + ' .toolbar .tabs .ribtab.active>a{color:var(--xr-label)!important}' +
      // Slides' Present (the Windows build paints it Office red with a 6 px radius): the editor's single primary
      // action = the Slides accent as a true capsule (a deeper shade of it in light mode, so the white label reaches
      // 4.5:1); dark label on the light dark-mode accent (contrast)
      K + ' .xr-present-btn{background:var(--xr-present)!important;border-radius:18px!important;height:36px!important;' +
        'display:inline-flex!important;align-items:center}' +
      K + ' .xr-present-btn:hover{background:var(--xr-present)!important;filter:brightness(.92)}' +
      K + ' .xr-present-label{color:var(--xr-on-accent)!important;font-family:inherit!important}' +
      K + ' .xr-present-btn .dropdown-toggle .caret{border-top-color:var(--xr-on-accent)!important}' +
      // primary dialog buttons (OK / Insert / Replace ...) on the teal tint: the engine's label is --text-inverse
      // (white in both themes) - the label follows the tint instead (black on the light dark-mode teal)
      K + ' .btn.primary,' + K + ' .btn.primary:hover,' + K + ' .btn.primary:active,' + K + ' .btn.primary.active{color:var(--xr-on-accent)!important}' +
      // the editor's own theme picker (Settings > Appearance): the app follows iOS and sets the theme on every open,
      // so a choice there would not stick - not offered (tab style / background are fixed in xr-editor.html)
      K + ' #panel-settings :is(tr.appearance,tr.themes,tr.tab-style,tr.tab-background,tr.divider-group:has(+tr.appearance)){display:none!important}' +
      // touch: no < > scroll arrows on the tab row - it scrolls under the finger, with a soft 24 px fade at both ends.
      // (a trackpad / mouse keeps the arrows: any-pointer:fine)
      '@media not all and (any-pointer:fine){' +
        '.toolbar .tabs .scroll{display:none!important}' +
        '.toolbar .tabs>ul{overflow-x:auto!important;overflow-y:hidden!important;scrollbar-width:none;' +
          'padding-left:12px!important;padding-right:12px!important;' +
          '-webkit-mask-image:linear-gradient(to right,transparent 0,#000 24px,#000 calc(100% - 24px),transparent 100%);' +
          'mask-image:linear-gradient(to right,transparent 0,#000 24px,#000 calc(100% - 24px),transparent 100%)}' +
        '.toolbar .tabs>ul::-webkit-scrollbar{display:none}}';
    var add = function () {
      if (document.getElementById('xr-chrome-css')) return;
      var s = document.createElement('style'); s.id = 'xr-chrome-css'; s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    };
    if (document.documentElement) add();
    document.addEventListener('DOMContentLoaded', add);
  })();

  // ONLYOFFICE "New: Paste options / Multipage view / ..." tips: never in Xrero. The editors show a tip unless
  // localStorage holds its "<de|sse|pe>-help-tip-<name>" key -> report every such key as already seen.
  (function noFeatureTips() {
    var re = /-help-tip-/;
    try {
      var gi = Storage.prototype.getItem;
      Storage.prototype.getItem = function (k) { return re.test(String(k)) ? '1' : gi.apply(this, arguments); };
    } catch (e) {}
    var n = 0, t = setInterval(function () {               // also the editors' in-memory store (no localStorage case)
      var ls = window.Common && Common.localStorage;
      if (ls && ls.getItem && !ls.getItem.__xr) {
        var g = ls.getItem;
        ls.getItem = function (k) { return re.test(String(k)) ? '1' : g.apply(this, arguments); };
        ls.getItem.__xr = true;
      }
      if (++n > 1200) clearInterval(t);
    }, 25);
  })();

  // Touch devices: when the keyboard opens, WebKit scrolls the page to reveal the editors' hidden input field and
  // the whole editor slides sideways. Pin that field to the corner and keep the page itself from scrolling.
  (function pinForTouch() {
    if (!(navigator.maxTouchPoints > 0)) return;
    var css = 'html,body{overflow:hidden!important;overscroll-behavior:none}' +
              '#area_id_parent{position:fixed!important;left:0!important;top:0!important}';
    var add = function () {
      if (document.getElementById('xr-touch-css')) return;
      var s = document.createElement('style'); s.id = 'xr-touch-css'; s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    };
    if (document.documentElement) add();
    document.addEventListener('DOMContentLoaded', add);
    var reset = function () { if (window.scrollX || window.scrollY) window.scrollTo(0, 0); };
    window.addEventListener('scroll', reset, { passive: true });
    if (window.visualViewport) window.visualViewport.addEventListener('scroll', reset, { passive: true });
  })();

  function editor() { return (window.Asc && window.Asc.editor) || window.editor; }
  function ext(name) { var m = /\.([A-Za-z0-9]+)$/.exec(name || ''); return m ? m[1].toLowerCase() : 'docx'; }

  // ---------------------------------------------------------------- x2t (WebAssembly) in a worker
  var worker = null, seq = 0, waiting = {};
  function x2t(name, data, to, mediaList, opts) {
    if (!worker) {
      worker = new Worker(H.x2tBase + 'x2t-worker.js?base=' + encodeURIComponent(H.x2tBase));
      worker.onmessage = function (e) { var w = waiting[e.data.id]; delete waiting[e.data.id]; w && (e.data.ok ? w.ok(e.data) : w.fail(new Error(e.data.error))); };
      worker.onerror = function (e) { log('x2t worker error', e.message); };
    }
    opts = opts || {};
    return new Promise(function (ok, fail) {
      var id = ++seq; waiting[id] = { ok: ok, fail: fail };
      worker.postMessage({ id: id, name: name, data: data, to: to, media: mediaList || [],
                           changes: opts.changes || [], fromChanges: !!opts.fromChanges, fonts: opts.fonts || null,
                           formatTo: opts.formatTo || 0 });
    });
  }
  // the editors' font files as absolute URLs (for x2t when it has to draw text: PDF editing)
  function fontUrls() {
    var ids = window.__fonts_files || [];
    return ids.map(function (id) { return new URL(H.fontUrl(id), location.href).href; });
  }

  // PDF: opened as-is by the PDF editor (its own WebAssembly engine renders it); saving = the original file + the
  // editor's compiled changes (annotations, forms, edited/added/deleted pages) applied by x2t, exactly what the
  // desktop's native PDF engine does (EditPdf + AddToPdfFromBinary). Always against the ORIGINAL bytes: the
  // changes describe the difference to the document as it was opened.
  function savePdf(ed, done, t0) {
    var dr = ed.WordControl && ed.WordControl.m_oDrawingDocument && ed.WordControl.m_oDrawingDocument.m_oDocumentRenderer;
    var changes = null;
    try { changes = dr && dr.Save ? dr.Save() : null; } catch (e) { log('save: pdf changes failed', e && e.stack || e); return done(2); }
    if (!changes || changes.length <= 4) {
      log('save: pdf has no changes');
      return H.saveFile(opened.name, opened.bin.slice(0)).then(function () { done(0); }, function (e) { log('save failed', e); done(2); });
    }
    var ch = changes.slice(0);                       // own copy (transferable)
    x2t('origin.pdf', opened.bin.slice(0), 'out.pdf', [], { changes: [{ name: 'changes0.bin', data: ch.buffer }], fromChanges: true, fonts: fontUrls() })
      .then(function (r) {
        if (r.data.byteLength < 8) throw new Error('empty pdf');
        return H.saveFile(opened.name, r.data).then(function () {
          log('saved', opened.name, r.data.byteLength, 'bytes (' + changes.length + ' bytes of PDF changes) in', Date.now() - t0, 'ms');
          done(0);
        });
      }).catch(function (e) { log('save failed', e && e.message || e); done(2); });
  }

  // ---------------------------------------------------------------- clipboard (Cut / Copy / Paste)
  // The desktop sdkjs hands the ribbon's / context menu's Cut, Copy and Paste to the shell
  // (asc_desktop_copypaste -> AscDesktopEditor.Copy/Cut/Paste); without these the buttons threw and did nothing.
  // Copy / Cut: sdkjs' own BROWSER path does the work (it writes text/plain + text/html to the system pasteboard
  // through the copy event and keeps its internal format for Xrero-to-Xrero pastes). It only takes that path when
  // no desktop shell is present, so the shell is hidden for the length of that one synchronous call - still inside
  // the user's tap, which WebKit requires for execCommand('copy').
  // Paste: WebKit gives a page no pasteboard access, so the app reads UIPasteboard on this tap only and hands the
  // text to __xrPaste below. Never on the keystroke path.
  var clipText = null;                        // plain text of Xrero's own last copy (recognised again on paste)
  function squash(s) { return String(s == null ? '' : s).replace(/[\s ​-‏‪-‮⁦-⁩]+/g, ''); }
  function webClipboard(method) {
    var api = window.__xrApi, fn = api && (api[method] || api['asc_' + method]);  // Word/Slides: Copy, Cells: asc_Copy
    if (typeof fn !== 'function') return false;
    var shell = window.AscDesktopEditor, r = false;
    window.AscDesktopEditor = undefined;
    try { r = fn.call(api); } catch (e) { log('clipboard', method, 'failed', e && e.message || e); }
    finally { window.AscDesktopEditor = shell; }
    return r;
  }
  function copyCut(cut) {
    var api = window.__xrApi, text = '';
    try { text = (api && api.asc_GetSelectedText && api.asc_GetSelectedText()) || ''; } catch (e) {}   // before a cut
    var C = window.AscCommon && AscCommon.g_clipboardBase;
    if (C) C.LastCopyBinary = null;           // refilled by the engine only when it really copied something
    var ok = !!webClipboard(cut ? 'Cut' : 'Copy') && !(C && !C.LastCopyBinary);
    clipText = text;
    // ok=false: WebKit did not write the pasteboard - the app writes the plain text itself
    H.command && H.command('copied', JSON.stringify({ ok: ok, text: String(text) }));
  }
  // Called by the app (EditorWebView.paste) with the pasteboard's plain text. Xrero's own copy (the pasteboard
  // still holds the text it wrote) goes back in with full formatting; anything else is inserted as plain text.
  window.__xrPaste = function (text) {
    var api = window.__xrApi, C = window.AscCommon && AscCommon.g_clipboardBase;
    if (!api || !api.asc_PasteData) return 'no editor';
    if (text == null || text === '') return 'empty';
    var F = (window.AscCommon && AscCommon.c_oAscClipboardDataFormat) || { Text: 1, Internal: 4 };
    try {
      if (C && C.IsWorking && C.IsWorking()) return 'busy';
      if (api.asc_enableKeyEvents) api.asc_enableKeyEvents(true, true);
      var internal = null, own = null;
      ((C && C.LastCopyBinary) || []).forEach(function (b) {
        if (b.type === F.Internal) internal = b.data; else if (b.type === F.Text) own = b.data;
      });
      var t = squash(text);
      if (internal == null || (t !== squash(own) && t !== squash(clipText))) log('paste detail: plain text (internal copy ' + (internal == null ? 'absent' : 'differs') + ')');
      if (internal != null && t && (t === squash(own) || t === squash(clipText))) {
        api.asc_PasteData(F.Internal, internal, null, own != null ? own : text);
        return 'internal';
      }
      api.asc_PasteData(F.Text, String(text));
      return 'text';
    } catch (e) { return 'error: ' + (e && e.message || e); }
  };

  // ---- Save As / Download As: the copy itself (formats: SAVE_AS at the top)
  var pendingCopy = null;                     // {bin, done} while the app asks which format
  // The app answers 'saveas' with the chosen extension ('' = cancelled). The engine waits (its save action is open)
  // until done() runs. done(1), never done(0): the document itself was NOT saved, so it must stay "modified".
  window.__xrSaveAs = function (want) {
    var p = pendingCopy; pendingCopy = null;
    if (!p) return 'nothing pending';
    var f = saveAsFormats().filter(function (x) { return x[0] === want; })[0];
    if (!f) { log('save as: cancelled'); p.done(1); return 'cancelled'; }
    if (!H.exportFile) { log('save as: host cannot export'); p.done(2); return 'no export'; }
    var name = opened.name.replace(/\.[^.\/]+$/, '') + '.' + f[0], t0 = Date.now();
    var list = Object.keys(media).map(function (n) { return { name: n, data: media[n].slice(0) }; });
    x2t('Editor.bin', p.bin.buffer, 'out.' + f[0], list, { formatTo: f[1] }).then(function (r) {
      if (r.data.byteLength < 8) throw new Error('empty ' + f[0]);
      return H.exportFile(name, r.data).then(function () {
        log('exported copy', name, r.data.byteLength, 'bytes in', Date.now() - t0, 'ms');
        p.done(1);
      });
    }).catch(function (e) { log('save as failed', e && e.message || e); p.done(2); });
    return 'ok';
  };

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
      // phones: show the whole page width instead of 100% zoom running off the screen
      try {
        api.asc_registerCallback('asc_onDocumentContentReady', function () {
          if (Math.min(window.innerWidth, screen.width) < 700) {
            // presentations: the slide strip would take half the phone; start with the slide at full width
            // (through the UI's own toggle so its button stays in sync, then let the layout re-measure)
            // (the UI wires its controllers a moment after the engine reports ready: wait for that)
            if (/presentationeditor/.test(location.pathname)) {
              var tries = 0, t = setInterval(function () {
                var lm = window.PE && PE.getController && PE.getController('LeftMenu');
                if (!(lm && lm.api && lm.leftMenu && lm.leftMenu.btnThumbs)) { if (++tries > 40) clearInterval(t); return; }
                clearInterval(t);
                try {
                  lm.leftMenu.btnThumbs.toggle(false);
                  if (window.Common && Common.NotificationCenter) Common.NotificationCenter.trigger('layout:changed', 'leftmenu');
                  window.dispatchEvent(new Event('resize'));
                } catch (e) { log('thumbnails', e); }
              }, 250);
            }
          }
          H.command && H.command('ready', '');
        });
      } catch (e) { log('ready hook', e); }
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
      var name, t0 = Date.now();
      H.openFile().then(function (f) {
        name = f.name;
        log('open', name, f.data.byteLength, 'bytes');
        if (ext(name) === 'pdf') return { data: f.data, media: [], ms: 0 };   // the PDF editor reads the file itself
        return x2t(name, f.data, 'Editor.bin');
      }).then(function (r) {
        log('converted to Editor.bin', r.data.byteLength, 'bytes,', r.media.length, 'pictures,', r.ms, 'ms convert,',
            Date.now() - t0, 'ms since open (incl. first x2t load)');
        opened = { name: name, ext: ext(name), bin: r.data };
        return Promise.all(r.media.map(function (m) { media[m.name] = m.data; return H.putMedia(m.name, m.data); }));
      }).then(function () {
        window.DesktopOfflineAppDocumentEndLoad(DOC_URL, 'binary_content://xr-open', opened.bin.byteLength);
      }).catch(function (e) {
        log('open failed', e && e.message || e);
        window.DesktopOfflineAppDocumentEndLoad(DOC_URL, '', 0);
      });
    },
    GetOpenedFile: function () { return opened ? (opened.ext === 'pdf' ? opened.bin.slice(0) : opened.bin) : null; },
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
      log('save start', opened.name);
      var t0 = Date.now(), bin;
      if (opened.ext === 'pdf') return savePdf(ed, done, t0);
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
      if (/saveas=true/.test(param || '')) {
        // A format chosen in the File menu's "Download As" tiles (fileType != 0) is used directly when it really
        // works; without one (the desktop's Save As / Ctrl+Shift+S, which ask a native dialog) the app lists them.
        var fmts = saveAsFormats();
        if (!fmts.length) { log('save as: no formats here'); return done(1); }
        if (pendingCopy) pendingCopy.done(1);
        pendingCopy = { bin: bin, done: done };
        var direct = fmts.filter(function (x) { return x[1] === fileType; })[0];
        log('save as: asking for a format', fileType ? '(editor asked for ' + fileType + ')' : '');
        if (direct) return window.__xrSaveAs(direct[0]);
        return H.command && H.command('saveas', fmts.map(function (x) { return x[0]; }).join(','));
      }
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
    Copy: function () { copyCut(false); },
    Cut: function () { copyCut(true); },
    Paste: function () { H.command && H.command('paste', ''); },
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
  // phones: touch-sized header rows. The editors lay their rows out with fixed heights (title 28, tabs 32) read from
  // InternalSettings when the viewport is built - set larger ones as soon as the settings exist, before that.
  var PHONE = Math.min(screen.width, screen.height) < 600;
  function phoneHeights() {
    var S = window.Common && Common.Utils && Common.Utils.InternalSettings;
    if (!(PHONE || TABLET) || !S || S.get('xr-phone')) return;
    S.set('xr-phone', true);
    var tabs = PHONE ? 46 : 40, title = PHONE ? 44 : 40;
    S.set('toolbar-height-tabs', tabs);
    S.set('toolbar-height-tabs-top-title', tabs);
    S.set('document-title-height', title);
    S.set('toolbar-height-compact', tabs);
    S.set('toolbar-height-normal', tabs + (S.get('toolbar-height-controls') || 84));
  }

  // phones: the ribbon's own overflow logic moves whole groups (font, paragraph, styles) into a "more" menu whose button
  // does not show on a phone-width folded toolbar - only cut / copy / paste stayed reachable. On phones every group stays
  // in its tab and the tab's row scrolls sideways under the finger instead.
  function phoneRibbon() {
    var M = window.Common && Common.UI && Common.UI.Mixtbar;
    if (!PHONE || !M || M.prototype.__xrPhone) return;
    M.prototype.__xrPhone = true;
    M.prototype.resizeToolbar = function () {
      var $active = this.$panels && this.$panels.filter('.active');
      if (this.$moreBar && $active && $active.length) {          // anything moved earlier goes back into its tab
        var back = this.$moreBar.children('.group,.separator,[data-hidden-tb-item]');
        if (back.length) $active.append(back);
      }
      $active && $active.find('.more-box').css('display', 'none');
    };
    M.prototype.resizeToolbar.__xr = true;
  }

  // iPad: the layout reserves "toolbar-height-normal" for the ribbon. phoneHeights sets it before the viewport is built
  // when it wins the race with the editor's start-up, but the controls row's real height is only known once the touch
  // CSS applies. So, once the ribbon exists: measure the tabs row and the controls row, store the real values and,
  // if the layout reserved less (the bottom of the ribbon was cut off), give the ribbon its height and re-lay out.
  function fitRibbon() {
    var S = window.Common && Common.Utils && Common.Utils.InternalSettings;
    if (!TABLET || !S) return;
    var tb = document.querySelector('#toolbar .toolbar'), tabs = tb && tb.querySelector('.box-tabs'),
      bc = tb && tb.querySelector('.box-controls');
    if (!tb || !tabs || !bc || !bc.offsetHeight || tb.classList.contains('folded')) return;
    var app = window.DE || window.PE || window.SSE || window.PDFE, vl = null;
    try { vl = app && app.getController('Viewport').viewport.vlayout; } catch (e) {}
    var item = vl && vl.getItem && vl.getItem('toolbar');
    if (!item) return;
    var ctrl = bc.offsetHeight, normal = tabs.offsetHeight + ctrl;
    if (S.get('toolbar-height-controls') !== ctrl) S.set('toolbar-height-controls', ctrl);
    if (S.get('toolbar-height-normal') !== normal) S.set('toolbar-height-normal', normal);
    if (item.height >= normal) return;
    item.height = normal;
    try { Common.NotificationCenter.trigger('layout:changed', 'toolbar'); } catch (e) { log('ribbon', e); }
  }

  function patchEngine() {
    phoneHeights();
    fitRibbon();
    phoneRibbon();
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
