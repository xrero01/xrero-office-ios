# Xrero Office for iPhone, iPad and Mac (Designed for iPad)

The Xrero desktop web editors (same `web-apps` + `sdkjs` as Windows/macOS) in a WKWebView, fully on the device:

* `web/xr-host.js` - stands in for the desktop shell's `window.AscDesktopEditor` (open/save/fonts/pictures/UI events)
  and talks to the app through `window.XreroHost`.
* `web/x2t-worker.js` - ONLYOFFICE x2t compiled to WebAssembly (`vendor/x2t-wasm`, CryptPad build v9.3.2+3,
  sha512 verified) converts .docx/.xlsx/.pptx <-> the editors' Editor.bin on the device. No server.
* `harness/` - runs the same code in a desktop browser (`serve.py`, `harness-host.js` = stand-in for the app).

Milestone 1 (2026-10-04): Writer, Calc and Slides open Arabic test documents; Writer saves a real .docx
(typed English + Arabic and the original content verified in the file; stamped "Xrero Office").
