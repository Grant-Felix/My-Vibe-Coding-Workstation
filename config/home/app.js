/* Vibe Coding Workstation — 门户交互
   零依赖、零构建。状态灯从真实探测结果得出，不写死。 */

(function () {
  'use strict';

  var ICONS = {
    terminal: '<path d="M4 17l6-5-6-5M12 19h8"/>',
    git:      '<circle cx="6" cy="6" r="2.2"/><circle cx="6" cy="18" r="2.2"/><circle cx="18" cy="12" r="2.2"/><path d="M6 8.2v7.6M8.2 6H13a3 3 0 013 3v1"/>',
    cloud:    '<path d="M7 18h9a4 4 0 000-8 5.5 5.5 0 00-10.6 1.4A3.5 3.5 0 007 18z"/>',
    code:     '<path d="M8 16l-4-4 4-4M16 8l4 4-4 4"/>',
    flask:    '<path d="M9 3h6M10 3v6L5.5 17A2 2 0 007.3 20h9.4A2 2 0 0018.5 17L14 9V3"/>',
    rocket:   '<path d="M12 3c3 2 4 6 4 9l-4 3-4-3c0-3 1-7 4-9z"/><path d="M9 18l3 3 3-3"/>'
  };

  function svg(name) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
           'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
           (ICONS[name] || ICONS.code) + '</svg>';
  }

  /* services.json 通过 fetch 读取。
     注意：<script src="x.json" type="application/json"> 不会加载外部内容——
     浏览器对非 JS 类型忽略 src，textContent 恒为空。这是必须用 fetch 的原因。 */
  function loadServices() {
    return fetch('services.json', { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (d) { return d.services || []; });
  }

  function card(s) {
    var a = document.createElement('a');
    a.className = 'card';
    a.href = 'https://' + s.host;
    a.style.setProperty('--c', s.accent);
    a.setAttribute('aria-label', s.name + ' — ' + s.desc);

    a.innerHTML =
      '<div class="icon">' + svg(s.icon) + '</div>' +
      '<div class="body">' +
        '<div class="name">' +
          '<span class="dot" data-dot="' + s.id + '"></span>' +
          '<span>' + s.name + '</span>' +
        '</div>' +
        '<div class="desc">' + s.desc + '</div>' +
        '<div class="host mono">' + s.host + '</div>' +
      '</div>';
    return a;
  }

  /* 真实探测：请求各服务主机名的 /healthz，据响应更新状态灯。
     用 no-cors 以免被 CORS 阻断——只要能连上就算在线。 */
  /* 状态灯三态：
       .dot          中性（尚未得出结论）
       .dot.ok       已确认在线
       .dot.down     已确认不可达
     卡片初始不带 ok/down，只有探测**确实失败**才转红——
     否则首次加载时满屏红色会让人误以为系统已坏。 */
  function probe(s) {
    var dot = document.querySelector('[data-dot="' + s.id + '"]');
    if (!dot) return Promise.resolve(false);

    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, 6000);

    return fetch('https://' + s.host + (s.health || '/'), {
      method: 'GET', mode: 'no-cors', cache: 'no-store', signal: ctrl.signal
    }).then(function () {
      dot.classList.remove('down'); dot.classList.add('ok');
      dot.title = '在线';
      return true;
    }).catch(function () {
      dot.classList.remove('ok'); dot.classList.add('down');
      dot.title = '不可达';
      return false;
    }).finally(function () { clearTimeout(timer); });
  }

  function tick() {
    var el = document.getElementById('clock');
    if (!el) return;
    var d = new Date();
    var p = function (n) { return String(n).padStart(2, '0'); };
    el.textContent = d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
                     ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  function main() {
    var grid = document.getElementById('grid');

    tick();
    setInterval(tick, 1000);

    loadServices().then(function (services) {
      if (!services.length) {
        grid.innerHTML = '<p class="loaderr">服务列表加载失败（services.json）。</p>';
        return;
      }
      services.forEach(function (s) { grid.appendChild(card(s)); });
      startHealthPolling(services);
    }).catch(function (e) {
      grid.innerHTML = '<p class="loaderr">服务列表加载失败：' + e.message + '</p>';
    });
  }

  function startHealthPolling(services) {

    function refresh() {
      Promise.all(services.map(probe)).then(function (results) {
        var up = results.filter(Boolean).length;
        var el = document.getElementById('status-summary');
        if (el) el.textContent = up + ' / ' + results.length + ' 服务在线';
      });
    }

    refresh();
    setInterval(refresh, 20000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else { main(); }
})();
