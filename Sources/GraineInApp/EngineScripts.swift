import Foundation

/**
 * The JavaScript this SDK puts into the engine page. Three small pieces, all
 * strings, so they are the same bytes on every build.
 */
enum EngineScripts {

    /**
     * THE BRIDGE. The page calls `window.ReactNativeWebView.postMessage(json)`
     * — it was written against React Native's WebView — so that object is
     * installed at document start, before the page's own scripts run, and
     * forwards every message to the WKScriptMessageHandler named "graine".
     * `String(s)` because a handler receives whatever type it is given.
     */
    static let bridge =
        "window.ReactNativeWebView = { postMessage: function(s){ window.webkit.messageHandlers.graine.postMessage(String(s)); } };"

    /// The message handler the debug console forwarder posts to.
    static let consoleHandlerName = "graineConsole"

    /**
     * DEBUG ONLY: the engine page's console, in the app's log. WKWebView has no
     * console callback (Android's onConsoleMessage), so console.* is wrapped and
     * each line is posted to the "graineConsole" handler, then passed on to the
     * original. Uncaught errors too. Installed only when `debug` is on; a
     * release build never sees it.
     */
    static let consoleForwarder = #"""
    (function(){
      if (window.__graineConsole) return; window.__graineConsole = true;
      var handlers = window.webkit && window.webkit.messageHandlers;
      var h = handlers && handlers.graineConsole;
      if (!h) return;
      function send(level, args) {
        try {
          var parts = [];
          for (var i = 0; i < args.length; i++) {
            var a = args[i];
            if (typeof a === 'string') parts.push(a);
            else { try { parts.push(JSON.stringify(a)); } catch (_) { parts.push(String(a)); } }
          }
          h.postMessage(level + ': ' + parts.join(' ').slice(0, 2000));
        } catch (_) {}
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function(level){
        var original = console[level];
        console[level] = function(){
          send(level, arguments);
          if (original) return original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function(e){
        send('error', ['uncaught: ' + (e && e.message) + ' @ ' + (e && e.filename) + ':' + (e && e.lineno)]);
      });
      window.addEventListener('unhandledrejection', function(e){
        send('error', ['unhandled rejection: ' + (e && e.reason)]);
      });
    })(); true;
    """#

    /**
     * DEBUG ONLY: what the engine's conversation socket actually carries —
     * verbatim from the Android SDK's SocketTrace.kt.
     *
     * "The agent did not speak" has three different causes — no audio arrived,
     * audio arrived and was not played, or the server closed the socket — and
     * from outside they look identical. This counts frames by type, prints the
     * non-audio ones, and prints the close code and reason.
     *
     * The URL is cut at '?', so a ticket or a context token never reaches the
     * log. Installed at did-finish: the page opens its socket only when a call
     * starts, which is after that.
     */
    static let socketTrace = #"""
(function(){
  if (window.__graineTrace) return; window.__graineTrace = true;
  var WS = window.WebSocket;
  function Traced(url, protocols) {
    var ws = protocols ? new WS(url, protocols) : new WS(url);
    var counts = {}; var path = String(url).split('?')[0];
    ws.addEventListener('open', function(){ console.log('[ws] open ' + path); });
    ws.addEventListener('message', function(e){
      var type = 'binary', text = '';
      if (typeof e.data === 'string') {
        try { var d = JSON.parse(e.data); type = d.type || d.event || '?'; if (typeof d.data === 'string') text = d.data.slice(0, 90); }
        catch(_) { type = 'text/raw'; }
      }
      counts[type] = (counts[type] || 0) + 1;
      var noisy = type === 'audio' || type === 'mark' || type === 'ping' || type === 'pong' || type === 'binary';
      if (!noisy) console.log('[ws] recv ' + type + (text ? ': ' + text : ''));
      else if (counts[type] === 1 || counts[type] % 100 === 0) console.log('[ws] recv ' + type + ' #' + counts[type]);
    });
    ws.addEventListener('close', function(e){
      console.log('[ws] close code=' + e.code + ' reason=' + (e.reason || '-') + ' clean=' + e.wasClean + ' frames=' + JSON.stringify(counts));
    });
    return ws;
  }
  Traced.prototype = WS.prototype;
  Traced.CONNECTING = WS.CONNECTING; Traced.OPEN = WS.OPEN; Traced.CLOSING = WS.CLOSING; Traced.CLOSED = WS.CLOSED;
  window.WebSocket = Traced;
})(); true;
"""#
}
