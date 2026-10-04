/* harness-host.js - the browser stand-in for the iOS app's native side (XreroHost), used to develop and test
   xr-host.js on a PC: documents come from /__doc/<name>, saves go to /__save/<name>, fonts from /__font. */
(function () {
  if (window.XreroHost) return;
  // like the iOS web view (custom URL scheme = no service workers): the editors must not register one here
  try { if (navigator.serviceWorker) navigator.serviceWorker.register = function () { return new Promise(function () {}); }; } catch (e) {}
  var top_ = window.top || window;
  var q = {};
  (top_.location.search || '').replace(/^\?/, '').split('&').forEach(function (kv) {
    var p = kv.split('='); if (p[0]) q[decodeURIComponent(p[0])] = decodeURIComponent((p[1] || '').replace(/\+/g, ' '));
  });
  window.XreroHost = {
    lang: (q.lang || 'en').slice(0, 2),
    theme: q.uitheme === 'theme-dark' ? 'dark' : 'light',
    title: q.title,
    openFile: function () {
      return fetch('/__doc/' + encodeURIComponent(q.title)).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.arrayBuffer();
      }).then(function (b) { return { name: q.title, data: b }; });
    },
    saveFile: function (name, bytes) {
      return fetch('/__save/' + encodeURIComponent(name), { method: 'POST', body: bytes }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
      });
    },
    putMedia: function (name, bytes) {
      return fetch('/__media/' + encodeURIComponent(name), { method: 'POST', body: bytes }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
      });
    },
    mediaUrl: function (name) { return location.origin + '/__media/' + encodeURIComponent(name); },
    x2tBase: location.origin + '/xr/',
    fontUrl: function (id) { return '/__font?id=' + encodeURIComponent(id); },
    fontsSprite: function (scale) { return '/__fontsprite?s=' + encodeURIComponent(scale || ''); },
    command: function (cmd, param) { console.log('[xr-cmd]', cmd, String(param || '').slice(0, 160)); (top_.__xrCmds = top_.__xrCmds || []).push([cmd, String(param || '').slice(0, 160)]); },
    log: function (m) { console.log('[xr]', m); (top_.__xrLog = top_.__xrLog || []).push(m); }
  };
})();
