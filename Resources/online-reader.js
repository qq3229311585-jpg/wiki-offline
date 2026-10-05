// 维基离线 · 页面脚本
// 职责：整理 DOM、切分翻译单元（与 Swift 端 UnitExtractor 规则一致）、应用译文、目录与滚动跟踪、与原生通信。
(function () {
  'use strict';

  // ===== 与 Sources/WikiCore/UnitExtractor.swift 保持一致 =====
  const UNIT_CANDIDATES = new Set(['P', 'LI', 'DD', 'DT', 'H2', 'H3', 'H4', 'H5', 'H6', 'TD', 'TH', 'CAPTION', 'FIGCAPTION', 'BLOCKQUOTE', 'DIV']);
  const UNIT_BLOCKS = new Set(['P', 'DIV', 'UL', 'OL', 'DL', 'TABLE', 'BLOCKQUOTE', 'PRE', 'FIGURE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
    'SECTION', 'DETAILS', 'SUMMARY', 'HR', 'LI', 'DD', 'DT', 'TR', 'TD', 'TH', 'TBODY', 'THEAD', 'TFOOT',
    'CAPTION', 'CENTER', 'HEADER', 'FOOTER', 'NAV', 'ASIDE', 'FORM', 'FIELDSET', 'FIGCAPTION', 'MAIN', 'ARTICLE', 'ADDRESS']);
  const UNIT_EXCLUDED_TAGS = new Set(['PRE', 'CODE', 'MATH', 'SVG', 'STYLE', 'SCRIPT', 'KBD', 'SAMP', 'TEXTAREA']);
  // 在线版：参考文献/注释（references、reflist）不翻译，保持英文原样——它们大多是英文刊名、作者和日期，
  // 逐条翻译只会让页面成倍变长、变吵，还白白多花翻译费。同时排除导航框、公式、目录。
  const UNIT_EXCLUDED_CLASSES = ['navbox', 'mwe-math-element', 'toc', 'references', 'reflist', 'mw-references-wrap', 'refbegin'];
  const TEXT_SKIP_CLASSES = ['reference', 'mw-ref', 'mw-editsection', 'mwe-math-element', 'sortkey', 'mw-cite-backlink'];
  const TEXT_SKIP_TAGS = new Set(['STYLE', 'SCRIPT']);

  function normText(s) { return s.replace(/\s+/g, ' ').trim(); }
  function translatable(s) { return /[A-Za-z][^]*[A-Za-z]/.test(s); }
  function cyrb53(str) {
    let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
    for (let i = 0, ch; i < str.length; i++) {
      ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761);
      h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
    h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
    h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
  }
  function hasClassIn(el, list) {
    const cl = el.classList;
    if (!cl || cl.length === 0) return false;
    for (const c of list) if (cl.contains(c)) return true;
    return false;
  }
  function isExcludedSubtree(el, stop) {
    for (let n = el; n && n !== stop; n = n.parentElement) {
      if (UNIT_EXCLUDED_TAGS.has(n.tagName) || hasClassIn(n, UNIT_EXCLUDED_CLASSES)) return true;
    }
    return false;
  }
  function textOf(node) {
    if (node.nodeType === 3) return node.data;
    if (node.nodeType !== 1) return '';
    if (TEXT_SKIP_TAGS.has(node.tagName) || hasClassIn(node, TEXT_SKIP_CLASSES)) return '';
    if (node.tagName === 'BR') return ' ';
    let s = '';
    for (const c of node.childNodes) s += textOf(c);
    return s;
  }
  // =============================================================

  const post = (msg) => { try { window.webkit.messageHandlers.reader.postMessage(msg); } catch (e) { /* 预览环境 */ } };
  const root = document.documentElement;
  const body = document.getElementById('wiki-body');
  const units = [];               // {el, key, text, order}
  const byKey = new Map();        // key -> [unit]
  let translations = {};
  let linkTitles = {};

  function tidy() {
    if (!body) return;
    // 展开所有折叠章节（移动版渲染会用 <details>）
    body.querySelectorAll('details').forEach(d => { d.open = true; });
    // 外部链接标记
    document.querySelectorAll('a[href]').forEach(a => {
      const h = a.getAttribute('href') || '';
      if (/^[a-z][a-z0-9+.-]*:/i.test(h) && !h.startsWith('wiki:')) a.classList.add('ext-link');
    });
    // 宽表格包一层，横向滚动不撑破版面
    body.querySelectorAll('table').forEach(t => {
      if (t.closest('.infobox') && !t.classList.contains('infobox')) return;
      if (t.classList.contains('infobox') || t.classList.contains('sidebar')) { t.classList.add('wiki-infobox'); return; }
      if (t.parentElement && t.parentElement.classList.contains('table-wrap')) return;
      const w = document.createElement('div');
      w.className = 'table-wrap';
      t.parentNode.insertBefore(w, t);
      w.appendChild(t);
    });
    // 开篇两栏：把"信息框 + 第一个章节标题之前的内容"包成 .lead-cols
    const container = document.querySelector('.mw-parser-output');
    if (container && !container.querySelector(':scope > .lead-cols')) {
      const kids = Array.from(container.children);
      let limit = kids.findIndex(el => el.matches('h2, .mw-heading, .mw-heading2'));
      if (limit < 0) limit = kids.length;
      const isBox = (el) => el.matches('table.infobox, table.wiki-infobox, table.sidebar, div.sidebar, aside.sidebar, .infobox, .sidebar, [class*="infobox"]') || !!el.querySelector(':scope > table.infobox, :scope > table.wiki-infobox');
      const boxes = kids.slice(0, limit).filter(isBox);
      if (boxes.length && limit > 0) {
        const wrap = document.createElement('div');
        wrap.className = 'lead-cols';
        container.insertBefore(wrap, kids[0]);
        for (let i = 0; i < limit; i++) wrap.appendChild(kids[i]);
        // 开篇可能有多个信息框/侧栏模板：合并成一个右栏容器，避免它们在同一个网格单元里重叠
        const side = document.createElement('div');
        side.className = 'lead-side';
        wrap.insertBefore(side, boxes[0]);
        for (const b of boxes) side.appendChild(b);
        // 图片不加载后，放图片的行只剩空白：标成 empty-row 隐藏
        side.querySelectorAll('tr').forEach(tr => {
          if (!tr.textContent.trim() && !tr.querySelector('.u, table')) tr.classList.add('empty-row');
        });
        // 资料卡默认折叠到约 8 行，太长的才出现“展开”按钮
        side.classList.add('collapsed');
        const btn = document.createElement('button');
        btn.type = 'button'; btn.className = 'lead-toggle'; btn.hidden = true;
        btn.addEventListener('click', () => {
          side.classList.toggle('collapsed');
          btn.textContent = side.classList.contains('collapsed') ? '展开资料卡 ▾' : '收起资料卡 ▴';
        });
        wrap.appendChild(btn);
      }
    }

    // 标题 id 兜底
    let n = 0;
    body.querySelectorAll('h2, h3, h4').forEach(h => {
      if (!h.id) {
        const inner = h.querySelector('[id]');
        h.id = inner ? inner.id : ('sec-' + (++n));
      }
    });
  }

  // 资料卡是否需要折叠：按当前内容高度判断（切换模式、译文写入后都会变）
  let leadCardTimer = 0;
  function refreshLeadCard() {
    cancelAnimationFrame(leadCardTimer);
    leadCardTimer = requestAnimationFrame(() => {
      const side = document.querySelector('.lead-side');
      const btn = document.querySelector('.lead-toggle');
      if (!side || !btn) return;
      const collapsed = side.classList.contains('collapsed');
      // 折叠时 scrollHeight 是完整高度，clientHeight 是被裁后的高度
      const cap = parseFloat(getComputedStyle(document.documentElement).fontSize) * 17.5;
      const needs = collapsed ? side.scrollHeight > cap + 24 : true;
      btn.hidden = !needs;
      if (!needs && collapsed) side.classList.remove('collapsed');
      btn.textContent = side.classList.contains('collapsed') ? '展开资料卡 ▾' : '收起资料卡 ▴';
    });
  }

  function markLede() {
    if (!body) return;
    for (const p of body.querySelectorAll('p.u')) {
      if (p.closest('table, .hatnote, blockquote, li')) continue;
      if (p.textContent.length < 80) continue;
      p.classList.add('lede');
      break;
    }
  }

  function fillMeta() {
    const meta = document.getElementById('article-meta');
    if (!meta || !body) return;
    let words = 0;
    for (const u of units) words += u.text.split(' ').length;
    const minutes = Math.max(1, Math.round(words / 230));
    const secs = body.querySelectorAll('h2').length;
    meta.textContent = `约 ${minutes} 分钟 · ${secs} 个章节`;
  }

  function articleLinks() {
    const out = [], seen = new Set();
    if (!body) return out;
    for (const a of body.querySelectorAll('a[href]')) {
      if (a.classList.contains('ext-link') || a.closest('.reference, .references, .mw-references-wrap')) continue;
      const p = pathOf(a);
      const t = normText(textOf(a));
      if (!p || !t) continue;
      const k = t + '\u0001' + p;
      if (seen.has(k)) continue;
      seen.add(k);
      out.push([t, p]);
      if (out.length >= 1500) break;
    }
    return out;
  }

  function makeUnit(el, inlineNodes, text, order) {
    const key = cyrb53(text);
    const en = document.createElement('span');
    en.className = 'en';
    el.insertBefore(en, inlineNodes[0]);
    for (const nd of inlineNodes) en.appendChild(nd);
    const tr = document.createElement('span');
    tr.className = 'tr';
    tr.lang = 'zh-Hans';
    en.after(tr);
    const rb = document.createElement('button');
    rb.className = 'retry';
    rb.textContent = '重试翻译';
    rb.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); el.classList.remove('failed'); post({ type: 'retry', key }); });
    tr.after(rb);
    el.classList.add('u');
    el.dataset.k = key;
    const u = { el, key, text, order };
    units.push(u);
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key).push(u);
  }

  // 与 UnitExtractor.extract 等价：标题 → 简介 → 正文（文档顺序）
  function collectUnits() {
    let order = 0;
    for (const id of ['article-title', 'article-desc']) {
      const el = document.getElementById(id);
      if (!el) continue;
      const nodes = Array.from(el.childNodes);
      const t = normText(nodes.map(textOf).join(''));
      if (nodes.length && translatable(t)) makeUnit(el, nodes, t, order++);
    }
    if (!body) return;
    const all = body.querySelectorAll('*');
    for (const el of all) {
      if (!UNIT_CANDIDATES.has(el.tagName)) continue;
      if (el.closest('.en')) continue;                 // 已在某个单元的行内段里
      if (isExcludedSubtree(el, body)) continue;
      const inline = [];
      for (const c of el.childNodes) {
        if (c.nodeType === 1 && UNIT_BLOCKS.has(c.tagName)) break;
        inline.push(c);
      }
      if (!inline.length) continue;
      let raw = '';
      for (const c of inline) raw += textOf(c);
      const t = normText(raw);
      if (!translatable(t)) continue;
      makeUnit(el, inline, t, order++);
    }
  }

  // ===== 译文应用 =====
  function linkify(u, zh, trEl) {
    // 译文模式保留站内链接：先用中文标题（含去括号的变体）定位，再退回译文里保留的英文原名
    const anchors = u.el.querySelectorAll(':scope > .en a[href]');
    if (!anchors.length) { trEl.textContent = zh; return; }
    let html = escapeHTML(zh);
    const used = new Set();
    for (const a of anchors) {
      if (a.classList.contains('ext-link')) continue;
      const p = pathOf(a);
      if (!p || used.has(p)) continue;
      const variants = [];
      const t = linkTitles[p];
      if (t) {
        variants.push(t);
        const base = t.replace(/[（(][^）)]*[）)]\s*$/, '').trim();
        if (base && base !== t) variants.push(base);
      }
      // 译文里常保留英文原名（例如"伯纳德·阿诺（Bernard Arnault）"），也让它可点
      const en = normText(textOf(a));
      if (en.length >= 3) variants.push(en);
      for (const v of variants) {
        const ev = escapeHTML(v);
        if (v.length < 2) continue;
        const i = html.indexOf(ev);
        if (i >= 0 && !insideTag(html, i)) {
          html = html.slice(0, i) + '<a href="' + escapeAttr(a.getAttribute('href')) + '" class="tr-link">' + ev + '</a>' + html.slice(i + ev.length);
          used.add(p);
          break;
        }
      }
    }
    trEl.innerHTML = html;
  }
  function insideTag(html, i) { const lt = html.lastIndexOf('<', i), gt = html.lastIndexOf('>', i); return lt > gt; }
  function escapeHTML(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function escapeAttr(s) { return escapeHTML(s).replace(/"/g, '&quot;'); }
  function pathOf(a) {
    try {
      const u = new URL(a.getAttribute('href'), location.href);
      if (u.protocol !== 'wiki:') return null;
      return decodeURIComponent(u.pathname.replace(/^\//, ''));
    } catch (e) { return null; }
  }

  // ===== 中文译文规整：直引号→弯引号、CJK 旁半角括号→全角、去掉标点旁多余空格 =====
  const CJK = /[\u3400-\u9FFF\uF900-\uFAFF\u3000-\u303F\uFF00-\uFFEF]/;
  function normalizeZh(s) {
    if (!s) return s;
    let t = s;
    // 成对直引号 → 弯引号（只处理引号里含中文的情况，避免破坏英文专名里的撇号）
    t = t.replace(/"([^"]{1,120}?)"/g, (m, inner) => (CJK.test(inner) ? '“' + inner + '”' : m));
    t = t.replace(/'([^']{1,60}?)'/g, (m, inner) => (CJK.test(inner) ? '‘' + inner + '’' : m));
    // 括号里有中文 → 全角括号
    t = t.replace(/\(([^()]{0,80}?)\)/g, (m, inner) => (CJK.test(inner) ? '（' + inner + '）' : m));
    // 全角标点紧贴文字，不留空格
    t = t.replace(/([，。、；：？！）】》”’])[ \t]+/g, '$1');
    t = t.replace(/[ \t]+([，。、；：？！（【《“‘])/g, '$1');
    // 中文字符之间被插入的空格
    t = t.replace(/([\u3400-\u9FFF]) +([\u3400-\u9FFF])/g, '$1$2');
    t = t.replace(/，{2,}/g, '，').replace(/。{2,}/g, '。').replace(/、{2,}/g, '、');
    return t;
  }

  // ===== 相邻全角标点挤压：给前一个加 .pc（letter-spacing 负值收窄）=====
  const FULL_PUNCT = new Set('，。、；：？！）】》”’」』'.split(''));
  function isFullPunct(ch) { return FULL_PUNCT.has(ch); }
  function squeezePunct(el) {
    if (!el) return;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    const targets = [];
    while (walker.nextNode()) {
      const t = walker.currentNode;
      if (t.data.length < 2) continue;
      for (let i = 0; i < t.data.length - 1; i++) {
        if (isFullPunct(t.data[i]) && isFullPunct(t.data[i + 1])) { targets.push(t); break; }
      }
    }
    for (const t of targets) {
      const s = t.data;
      const frag = document.createDocumentFragment();
      let buf = '';
      for (let i = 0; i < s.length; i++) {
        const ch = s[i], next = s[i + 1];
        if (isFullPunct(ch) && next && isFullPunct(next)) {
          if (buf) { frag.appendChild(document.createTextNode(buf)); buf = ''; }
          const sp = document.createElement('span');
          sp.className = 'pc';
          sp.textContent = ch;
          frag.appendChild(sp);
        } else {
          buf += ch;
        }
      }
      if (buf) frag.appendChild(document.createTextNode(buf));
      t.parentNode.replaceChild(frag, t);
    }
  }

  function applyOne(key, zh, animate, seq = 0) {
    const list = byKey.get(key);
    if (!list) return 0;
    const clean = normalizeZh(zh);
    translations[key] = clean;
    for (const u of list) {
      const tr = u.el.querySelector(':scope > .tr');
      if (!tr) continue;
      linkify(u, clean, tr);
      squeezePunct(tr);
      // 拉丁字母多（学名、外文专名）的段落不做两端对齐，避免字距被拉开
      const latin = (clean.match(/[A-Za-z]/g) || []).length;
      u.el.classList.toggle('lat', latin / Math.max(clean.length, 1) > 0.05);
      u.el.classList.add('has-tr');
      u.el.classList.remove('pending');
      if (animate) {
        u.el.classList.remove('fresh');
        // 同一批译文错峰浮现：每段晚 70ms，最多错开 6 段，读起来像文字一段段长出来
        u.el.style.setProperty('--td', (Math.min(seq, 6) * 0.07).toFixed(2) + 's');
        void u.el.offsetWidth;
        u.el.classList.add('fresh');
      }
    }
    return list.length;
  }

  // ===== 目录与滚动 =====
  let headings = [];
  function buildTOC() {
    headings = body ? Array.from(body.querySelectorAll('h2, h3')).filter(h => normText(h.textContent).length > 0) : [];
    return headings.map(h => ({
      id: h.id,
      level: h.tagName === 'H2' ? 2 : 3,
      text: normText((h.querySelector(':scope > .en') || h).textContent),
      key: h.dataset.k || null,
    }));
  }

  // 初值用 undefined：页面加载后的第一次 updateSection 一定要把"共几节"发出去
  let currentSection;
  // 一级章节（h2）的序号：-1 表示还停在导语；total 统计整篇的 h2 数量
  function sectionCounts() {
    const y = 96;
    let total = 0, n = 0;
    for (const h of headings) {
      if (h.tagName !== 'H2') continue;
      total++;
      if (h.getBoundingClientRect().top <= y) n++;
    }
    return { index: n - 1, total };
  }
  function updateSection() {
    const y = 96;
    let cur = null;
    for (const h of headings) {
      if (h.getBoundingClientRect().top <= y) cur = h; else break;
    }
    const id = cur ? cur.id : null;
    if (id !== currentSection) {
      currentSection = id;
      const c = sectionCounts();
      post({ type: 'section', id, index: c.index, total: c.total, fraction: scrollFraction() });
    }
  }

  const visible = new Set();
  let vpTimer = null;
  function reportViewport() {
    clearTimeout(vpTimer);
    vpTimer = setTimeout(() => {
      let first = Infinity, last = -1;
      for (const o of visible) { if (o < first) first = o; if (o > last) last = o; }
      if (last < 0) {
        // 没有可见单元（例如停在大表格中间）：用滚动位置估计
        const f = scrollFraction();
        const o = Math.floor(f * units.length);
        first = Math.max(0, o - 5); last = o + 10;
      }
      post({ type: 'viewport', first, last });
    }, 120);
  }

  function scrollFraction() {
    const h = document.documentElement.scrollHeight - window.innerHeight;
    return h > 0 ? Math.min(1, Math.max(0, window.scrollY / h)) : 0;
  }

  let ticking = false, scrollTimer = null, lastFraction = -1;
  window.addEventListener('scroll', () => {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(() => {
        ticking = false;
        updateSection();
        const f = scrollFraction();
        if (Math.abs(f - lastFraction) > 0.002) { lastFraction = f; post({ type: 'progress', fraction: f }); }
      });
    }
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => {
      const f = scrollFraction();
      lastFraction = f;
      post({ type: 'scroll', fraction: f });
    }, 400);
  }, { passive: true });

  // ===== 原生调用的接口 =====
  window.Reader = {
    setMode(mode) {
      root.dataset.mode = mode;
      refreshLeadCard();
      reportViewport();
    },
    applyTranslations(pairs, animate = true) {
      let n = 0, seq = 0;
      for (const [k, zh] of pairs) n += applyOne(k, zh, animate, seq++);
      refreshLeadCard();
      return n;
    },
    markFailed(keys) {
      for (const k of keys) {
        const list = byKey.get(k);
        if (list) for (const u of list) { u.el.classList.remove('pending'); u.el.classList.add('failed'); }
      }
    },
    setTheme(t) { if (t === 'system') delete root.dataset.theme; else root.dataset.theme = t; },
    markPending(keys, on = true) {
      for (const k of keys) {
        const list = byKey.get(k);
        if (list) for (const u of list) u.el.classList.toggle('pending', on);
      }
    },
    clearPending() { document.querySelectorAll('.u.pending').forEach(e => e.classList.remove('pending')); },
    setLinkTitles(map) { Object.assign(linkTitles, map); },
    /// 标题库更新后（术语表就绪 / 新译文写回）重新给已上屏的段落挂链接
    relink() {
      let n = 0;
      for (const k of Object.keys(translations)) {
        const list = byKey.get(k);
        if (!list) continue;
        for (const u of list) {
          if (!u.el.classList.contains('has-tr')) continue;
          const tr = u.el.querySelector(':scope > .tr');
          if (!tr) continue;
          linkify(u, translations[k], tr);
          squeezePunct(tr);
          n++;
        }
      }
      return n;
    },
    setFontScale(x) { root.style.setProperty('--fs', String(x)); },
    setLineHeight(x) { root.style.setProperty('--lhs', String(x)); },
    setFont(f) { if (!f || f === 'song') delete root.dataset.font; else root.dataset.font = f; },
    setWidth(w) { if (!w || w === 'standard') delete root.dataset.width; else root.dataset.width = w; },
    setBilingualSide(on) { if (on) root.dataset.bi = 'side'; else delete root.dataset.bi; },
    scrollToSection(id) {
      const el = document.getElementById(id);
      if (!el) return;
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
    },
    scrollToFraction(f) {
      const h = document.documentElement.scrollHeight - window.innerHeight;
      window.scrollTo({ top: Math.max(0, h * f), behavior: 'instant' });
    },
    scrollToTop() { window.scrollTo({ top: 0, behavior: 'smooth' }); },
    stats() { return { units: units.length, translated: Object.keys(translations).length }; },
    unitKeys() { return Array.from(byKey.keys()); },
  };

  // ===== 启动 =====
  function boot() {
    tidy();
    try {
      const c = document.getElementById('wiki-tr-cache');
      if (c) {
        const data = JSON.parse(c.textContent || '{}');
        translations = data.t || {};
        linkTitles = data.l || {};
      }
    } catch (e) { translations = {}; }
    collectUnits();
    markLede();
    fillMeta();
    // 缓存的译文立刻上屏（无动画）——"秒开"
    let cached = 0;
    for (const k of Object.keys(translations)) if (byKey.has(k)) cached += applyOne(k, translations[k], false) > 0 ? 1 : 0;

    // 可见性跟踪
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        const o = +e.target.dataset.o;
        if (e.isIntersecting) visible.add(o); else visible.delete(o);
      }
      reportViewport();
    }, { rootMargin: '0px 0px 0px 0px' });
    for (const u of units) { u.el.dataset.o = u.order; io.observe(u.el); }

    const pending = [];
    const seen = new Set();
    for (const u of units) {
      if (seen.has(u.key)) continue;
      seen.add(u.key);
      if (!(u.key in translations)) {
        const links = [];
        const en = u.el.querySelector(':scope > .en');
        if (en) en.querySelectorAll('a[href]').forEach(a => {
          if (a.classList.contains('ext-link') || a.closest('.reference')) return;
          const p = pathOf(a);
          const t = normText(textOf(a));
          if (p && t) links.push([t, p]);
        });
        pending.push([u.key, u.text, u.order, links]);
      }
    }
    const titleEl = document.getElementById('article-title');
    post({
      type: 'ready',
      path: (document.querySelector('meta[name="wiki-path"]') || {}).content || '',
      missing: !!document.querySelector('meta[name="wiki-missing"]'),
      title: titleEl ? normText(textOf(titleEl.querySelector(':scope > .en') || titleEl)) : document.title,
      titleKey: titleEl ? (titleEl.dataset.k || null) : null,
      total: seen.size,
      cached,
      units: pending,
      links: articleLinks(),
      toc: buildTOC(),
    });
    updateSection();
    refreshLeadCard();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(refreshLeadCard);
    reportViewport();
  }

  // ⌥ 点击译文：临时查看这一段的原文（带链接）
  document.addEventListener('click', (e) => {
    if (!e.altKey) return;
    const u = e.target.closest('.u.has-tr');
    if (!u) return;
    e.preventDefault();
    u.classList.toggle('peek');
  }, true);

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
