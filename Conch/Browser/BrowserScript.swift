import Foundation

/// The page-side half of browser automation. It runs in Conch's own JavaScript
/// world, so pages can't see or tamper with it, while it still shares their DOM.
///
/// Pages are described as readable text with interactive elements inline, each
/// tagged with a ref (`[e5 button "登录"]`) that later actions refer to. Refs stay
/// stable for the life of the document.
enum BrowserScript {
    static let source = #"""
    (() => {
    if (window.__conch && window.__conch.version === 3) return;
    const C = window.__conch = { version: 3, next: 1, refs: new Map(), ids: new WeakMap() };

    const ROLES = new Set(['button','link','checkbox','radio','tab','menuitem','menuitemcheckbox','menuitemradio',
      'option','switch','combobox','textbox','searchbox','slider','spinbutton','treeitem','listbox']);
    const SKIP = new Set(['script','style','noscript','template','head','meta','link','title','path','defs','symbol']);
    const BLOCK = new Set(['block','flex','grid','list-item','table','table-row','flow-root','table-caption','table-row-group',
      'table-header-group','table-footer-group']);
    const TEXTLIKE = new Set(['textbox','searchbox','spinbutton','combobox']);

    const clean = (s, n = 80) => {
      s = String(s ?? '').replace(/\s+/g, ' ').trim();
      return s.length > n ? s.slice(0, n - 1) + '…' : s;
    };
    const quote = s => '"' + s.replace(/"/g, "'") + '"';

    C.refFor = el => {
      let id = C.ids.get(el);
      if (!id) {
        id = 'e' + C.next++;
        C.ids.set(el, id);
        C.refs.set(id, new WeakRef(el));
      }
      return id;
    };

    C.get = ref => {
      const el = C.refs.get(String(ref).trim().replace(/^\[|\]$/g, ''))?.deref();
      if (!el || !el.isConnected) throw new Error('stale');
      return el;
    };

    const inputType = el => (el.getAttribute('type') || 'text').toLowerCase();

    function roleOf(el, style, parentCursor) {
      const aria = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
      if (ROLES.has(aria)) return aria;
      const tag = el.localName;
      if (tag === 'a') return el.hasAttribute('href') ? 'link' : (el.hasAttribute('onclick') ? 'button' : null);
      if (tag === 'button' || tag === 'summary') return 'button';
      if (tag === 'select') return 'select';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'input') {
        const type = inputType(el);
        if (type === 'hidden') return null;
        if (type === 'checkbox' || type === 'radio') return type;
        if (['submit', 'button', 'reset', 'image'].includes(type)) return 'button';
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (type === 'password') return 'password';
        if (type === 'file') return 'file';
        if (type === 'search') return 'searchbox';
        return 'textbox';
      }
      if (el.isContentEditable && !el.parentElement?.isContentEditable) return 'textbox';
      if (el.hasAttribute('onclick')) return 'clickable';
      const tabindex = el.getAttribute('tabindex');
      const pointer = style.cursor === 'pointer' && parentCursor !== 'pointer';
      if ((pointer || (tabindex !== null && +tabindex >= 0)) && !['html', 'body', 'label', 'img'].includes(tag)
          && !el.querySelector('a[href],button,input,select,textarea,[role=button],[role=link],[onclick]')
          && (el.innerText || '').length < 200) return 'clickable';
      return null;
    }

    function nameOf(el, role) {
      const aria = el.getAttribute('aria-label');
      if (aria && aria.trim()) return clean(aria);
      const labelledBy = el.getAttribute('aria-labelledby');
      if (labelledBy) {
        const text = labelledBy.split(/\s+/).map(id => el.ownerDocument.getElementById(id)?.textContent || '').join(' ');
        if (text.trim()) return clean(text);
      }
      if (el.labels && el.labels.length) {
        // A label that wraps its control would otherwise also read out the control's own text.
        const text = Array.from(el.labels).map(label => {
          const copy = label.cloneNode(true);
          copy.querySelectorAll('select,textarea,input,button').forEach(n => n.remove());
          return copy.textContent;
        }).join(' ');
        if (text.trim()) return clean(text);
      }
      if (el.localName === 'input') {
        const type = inputType(el);
        if (['submit', 'button', 'reset'].includes(type)) return clean(el.value || type);
        if (type === 'image') return clean(el.alt || 'image');
      }
      let text = '';
      if (!TEXTLIKE.has(role) && role !== 'password' && role !== 'select') text = clean(el.innerText || el.textContent);
      if (!text) text = clean(el.querySelector?.('img[alt]')?.alt);
      if (!text) text = clean(el.getAttribute('title') || el.getAttribute('placeholder'));
      if (!text) text = clean(el.querySelector?.('svg title')?.textContent);
      if (!text && el.localName === 'input') text = clean(el.getAttribute('name'));
      return text;
    }

    function shortHref(el) {
      const raw = el.getAttribute('href') || '';
      if (!raw || raw.startsWith('javascript:')) return '';
      if (raw.startsWith('#')) return raw.length > 1 ? clean(raw, 60) : '';
      try {
        const url = new URL(raw, el.baseURI);
        // Long tracking queries only cost tokens; keep the path.
        const query = (url.search + url.hash).length > 40 ? (url.search ? '?…' : '') : url.search + url.hash;
        if (url.origin === location.origin) return clean(url.pathname + query, 80);
        return clean(url.host + url.pathname, 80);
      } catch { return ''; }
    }

    function checked(el) {
      if ('checked' in el && (el.type === 'checkbox' || el.type === 'radio')) return el.checked;
      const aria = el.getAttribute('aria-checked') ?? el.getAttribute('aria-pressed');
      return aria === null ? null : aria === 'true';
    }

    C.describe = (el, role) => {
      const ref = C.refFor(el);
      let s = '[' + ref + ' ' + role;
      const name = nameOf(el, role);
      if (name) s += ' ' + quote(name);
      if (TEXTLIKE.has(role) && role !== 'combobox' || (role === 'combobox' && 'value' in el)) {
        const value = 'value' in el ? el.value : el.innerText;
        if (value) s += ' value=' + quote(clean(value, 160));
        const placeholder = el.getAttribute('placeholder');
        if (placeholder && clean(placeholder) !== name) s += ' placeholder=' + quote(clean(placeholder, 60));
        if (el.localName === 'input' && !['text', 'search', 'number'].includes(inputType(el))) s += ' type=' + inputType(el);
      }
      if (role === 'password' && el.value) s += ' (filled)';
      if (role === 'select') {
        const options = Array.from(el.options || []);
        const selected = options.filter(o => o.selected).map(o => clean(o.text, 40));
        if (selected.length) s += ' selected=' + quote(selected.join(', '));
        const list = options.slice(0, 15).map(o => clean(o.text, 30)).join(' | ');
        s += ' options=[' + list + (options.length > 15 ? ' | …' + options.length + ' total' : '') + ']';
      }
      if (role === 'link') {
        const href = shortHref(el);
        if (href) s += ' → ' + href;
      }
      const state = checked(el);
      if (state !== null && ['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio', 'button'].includes(role)) {
        s += state ? ' checked' : (role === 'button' ? '' : ' unchecked');
      }
      if (el.getAttribute('aria-expanded') === 'true') s += ' expanded';
      if (el.getAttribute('aria-selected') === 'true') s += ' selected';
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' disabled';
      if (el.required || el.getAttribute('aria-required') === 'true') s += ' required';
      if (el === el.ownerDocument.activeElement) s += ' focused';
      return s + ']';
    };

    /// Walks the rendered page in reading order. `viewport` limits it to what's on screen.
    C.render = (viewport) => {
      const out = [];
      const newline = () => { if (out.length && out[out.length - 1] !== '\n') out.push('\n'); };
      const vw = innerWidth, vh = innerHeight;
      if (!vw || !vh) viewport = false;

      const walk = (node, parentCursor, win) => {
        if (node.nodeType === 3) {
          const text = node.nodeValue.replace(/\s+/g, ' ');
          if (text.trim()) out.push(text);
          return;
        }
        if (node.nodeType === 11) { for (const child of node.childNodes) walk(child, parentCursor, win); return; }
        if (node.nodeType !== 1) return;
        const el = node, tag = el.localName;
        if (SKIP.has(tag) || el.hasAttribute('data-conch-overlay')) return;
        if (tag === 'br') { out.push('\n'); return; }
        if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return;
        const style = win.getComputedStyle(el);
        if (style.display === 'none') return;
        if (style.display === 'contents') {
          for (const child of (el.shadowRoot || el).childNodes) walk(child, parentCursor, win);
          return;
        }
        const rect = el.getBoundingClientRect();
        const invisible = style.visibility === 'hidden' || style.visibility === 'collapse';
        if (viewport && win === window && rect.width + rect.height > 0 &&
            (rect.bottom < 0 || rect.top > vh || rect.right < 0 || rect.left > vw)) return;

        const role = invisible ? null : roleOf(el, style, parentCursor);
        const tiny = rect.width < 1 && rect.height < 1;
        const block = BLOCK.has(style.display) || /^h[1-6]$/.test(tag);

        if (role && !(tiny && !['checkbox', 'radio'].includes(role))) {
          if (block) newline();
          out.push(' ' + C.describe(el, role) + ' ');
          if (block) newline();
          const container = ['clickable', 'option', 'treeitem', 'menuitem', 'tab'].includes(role);
          if (!container || !el.querySelector('a[href],button,input,select,textarea')) return;
        }

        if (tag === 'img' && !invisible) {
          const alt = clean(el.alt, 60);
          if (alt && !tiny) out.push(' [img ' + quote(alt) + '] ');
          return;
        }
        if (tag === 'iframe') {
          let doc = null;
          try { doc = el.contentDocument; } catch {}
          newline();
          if (doc && doc.body) walk(doc.body, 'auto', el.contentWindow);
          else if (!tiny) out.push('[iframe ' + clean(el.src || '', 60) + ' (cross-origin, not readable)]');
          newline();
          return;
        }
        if (block) newline();
        const heading = /^h([1-6])$/.exec(tag);
        if (heading) out.push('#'.repeat(+heading[1]) + ' ');
        if (tag === 'li') out.push('- ');
        const cursor = style.cursor;
        if (el.shadowRoot) {
          for (const child of el.shadowRoot.childNodes) walk(child, cursor, win);
        } else if (tag === 'slot') {
          for (const child of el.assignedNodes({ flatten: true })) walk(child, cursor, win);
        } else if (!invisible || el.childElementCount) {
          for (const child of el.childNodes) {
            if (invisible && child.nodeType === 3) continue;
            walk(child, cursor, win);
          }
        }
        if (style.display === 'table-cell') out.push(' | ');
        if (block) newline();
      };

      walk(document.body || document.documentElement, 'auto', window);
      return out.join('')
        .replace(/[ \t]+/g, ' ')
        .replace(/ *\n */g, '\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
    };

    function scroller() {
      const root = document.scrollingElement || document.documentElement;
      if (root.scrollHeight > innerHeight + 20) return root;
      // Apps that scroll an inner pane instead of the page.
      let best = null, area = 0;
      for (const el of document.querySelectorAll('body *')) {
        if (el.scrollHeight <= el.clientHeight + 20) continue;
        const overflow = getComputedStyle(el).overflowY;
        if (overflow !== 'auto' && overflow !== 'scroll') continue;
        const r = el.getBoundingClientRect();
        if (r.width * r.height > area) { area = r.width * r.height; best = el; }
      }
      return best || root;
    }

    C.info = () => {
      const s = scroller();
      const active = document.activeElement;
      return {
        title: document.title, url: location.href,
        scrollTop: Math.round(s.scrollTop), scrollHeight: s.scrollHeight, viewHeight: s === document.scrollingElement ? innerHeight : s.clientHeight,
        focused: active && active !== document.body && C.ids.has(active) ? C.ids.get(active) : null,
      };
    };

    C.snapshot = (mode, start, limit) => {
      const text = C.render(mode === 'viewport');
      return Object.assign(C.info(), { text: text.slice(start, start + limit), total: text.length });
    };

    C.find = (query, limit) => {
      const needle = String(query).toLowerCase();
      const lines = C.render(false).split('\n').filter(l => l.toLowerCase().includes(needle));
      return Object.assign(C.info(), { matches: lines.slice(0, limit).map(l => clean(l, 300)), total: lines.length });
    };

    // A ring around the element being worked on, so the person can follow along.
    C.unmark = (delay) => {
      const ring = C.ring;
      C.ring = null;
      if (!ring) return;
      setTimeout(() => { ring.style.opacity = '0'; setTimeout(() => ring.remove(), 400); }, delay || 0);
    };

    C.mark = (ref) => {
      const el = C.get(ref);
      C.unmark(0);
      el.scrollIntoView({ block: 'center', inline: 'nearest' });
      const doc = el.ownerDocument, win = doc.defaultView;
      const r = el.getBoundingClientRect();
      const ring = doc.createElement('div');
      ring.setAttribute('data-conch-overlay', '');
      Object.assign(ring.style, {
        position: 'absolute', left: (r.left + win.scrollX - 4) + 'px', top: (r.top + win.scrollY - 4) + 'px',
        width: (r.width + 8) + 'px', height: (r.height + 8) + 'px', boxSizing: 'border-box',
        border: '2px solid #D97757', borderRadius: '8px', background: 'rgba(217,119,87,0.12)',
        boxShadow: '0 0 0 4px rgba(217,119,87,0.22)', zIndex: '2147483647', pointerEvents: 'none',
        transition: 'opacity .35s ease', opacity: '1', margin: '0', padding: '0',
      });
      (doc.body || doc.documentElement).appendChild(ring);
      C.ring = ring;

      const role = roleOf(el, win.getComputedStyle(el), 'auto') || el.localName;
      const form = el.form || el.closest('form');
      const type = el.localName === 'input' ? inputType(el) : (el.getAttribute('type') || '').toLowerCase();
      const submits = !!form && (el.localName === 'button' ? type !== 'button' && type !== 'reset' : type === 'submit' || type === 'image');
      const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
      const hint = [el.getAttribute('name'), el.id, auto, el.getAttribute('placeholder'), nameOf(el, role)].join(' ').toLowerCase();
      return {
        role, name: nameOf(el, role), line: C.describe(el, role), submits, href: shortHref(el),
        password: type === 'password',
        payment: auto.startsWith('cc-') || /card.?number|cardnum|cvv|cvc|security.?code|卡号|安全码/.test(hint),
        editable: el.isContentEditable || el.localName === 'textarea' || (el.localName === 'input' && !['checkbox', 'radio', 'submit', 'button', 'reset', 'image', 'file', 'range', 'color'].includes(type)),
        tag: el.localName, formHost: form?.action ? (() => { try { return new URL(form.action).host; } catch { return ''; } })() : '',
      };
    };

    function covering(el) {
      const r = el.getBoundingClientRect();
      const x = r.left + r.width / 2, y = r.top + r.height / 2;
      const top = el.ownerDocument.elementFromPoint(x, y);
      if (!top || top === el || el.contains(top) || top.contains(el) || top.hasAttribute('data-conch-overlay')) return null;
      return clean(top.innerText || top.getAttribute('aria-label') || top.localName, 60);
    }

    C.click = (ref) => {
      const el = C.get(ref);
      const covered = covering(el);
      // Keep new-window links in this tab, where the assistant can keep working.
      const anchor = el.closest('a[target]');
      if (anchor && anchor.target !== '_self') anchor.target = '_self';
      const form = el.form || el.closest('form');
      if (form && form.target && form.target !== '_self') form.target = '_self';
      const r = el.getBoundingClientRect();
      const opts = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
      // Deferred, so a page that opens alert() can't block this call.
      setTimeout(() => {
        el.dispatchEvent(new PointerEvent('pointerover', opts));
        el.dispatchEvent(new MouseEvent('mouseover', opts));
        el.dispatchEvent(new PointerEvent('pointerdown', { ...opts, buttons: 1, pointerType: 'mouse', isPrimary: true }));
        el.dispatchEvent(new MouseEvent('mousedown', { ...opts, buttons: 1 }));
        if (el.focus) el.focus({ preventScroll: true });
        el.dispatchEvent(new PointerEvent('pointerup', { ...opts, pointerType: 'mouse', isPrimary: true }));
        el.dispatchEvent(new MouseEvent('mouseup', opts));
        el.click();
      }, 0);
      C.unmark(700);
      // A submit button does nothing while required fields are empty or invalid; say which.
      let invalid = [];
      const submits = form && (el.localName === 'button' ? !['button', 'reset'].includes((el.getAttribute('type') || '').toLowerCase())
        : ['submit', 'image'].includes(inputType(el)));
      if (submits && !form.noValidate && !form.checkValidity()) {
        invalid = Array.from(form.elements).filter(f => f.willValidate && !f.checkValidity())
          .map(f => C.describe(f, roleOf(f, getComputedStyle(f), 'auto') || f.localName) + ' ' + f.validationMessage);
      }
      return { covered, invalid };
    };

    function pressEnter(el) {
      const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
      const handled = !el.dispatchEvent(new KeyboardEvent('keydown', opts));
      el.dispatchEvent(new KeyboardEvent('keypress', opts));
      el.dispatchEvent(new KeyboardEvent('keyup', opts));
      if (handled || el.localName === 'textarea') return;
      const form = el.form || el.closest('form');
      if (!form) return;
      if (form.target && form.target !== '_self') form.target = '_self';
      if (form.requestSubmit) form.requestSubmit(); else form.submit();
    }

    C.type = (ref, text, clear, submit) => {
      const el = C.get(ref);
      el.focus({ preventScroll: true });
      const doc = el.ownerDocument;
      if ('value' in el && el.localName !== 'select') {
        const before = el.value;
        try {
          if (clear) el.select();
          else el.setSelectionRange(before.length, before.length);
        } catch {}
        const expected = clear ? text : before + text;
        let ok = false;
        try { ok = doc.execCommand('insertText', false, text); } catch {}
        if (!ok || el.value !== expected) {
          // Frameworks such as React track the value; go through the native setter so they notice.
          const proto = Object.getPrototypeOf(el);
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) setter.call(el, expected); else el.value = expected;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
        }
        el.dispatchEvent(new Event('change', { bubbles: true }));
      } else {
        if (clear) {
          const range = doc.createRange();
          range.selectNodeContents(el);
          const sel = doc.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        }
        if (!doc.execCommand('insertText', false, text)) {
          el.textContent = clear ? text : el.textContent + text;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
        }
      }
      C.unmark(500);
      const value = 'value' in el ? el.value : el.innerText;
      if (submit) setTimeout(() => pressEnter(el), 0);
      return { value: clean(value, 200) };
    };

    C.select = (ref, wanted) => {
      const el = C.get(ref);
      if (el.localName !== 'select') throw new Error('notselect');
      const want = String(wanted).trim().toLowerCase();
      const options = Array.from(el.options);
      const match = options.find(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want)
        || options.find(o => o.text.toLowerCase().includes(want));
      if (!match) return { error: 'nooption', options: options.slice(0, 40).map(o => clean(o.text, 40)) };
      el.focus({ preventScroll: true });
      const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set;
      setter.call(el, match.value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      C.unmark(500);
      return { value: clean(match.text, 60) };
    };

    C.scroll = (direction, ref) => {
      if (ref) {
        C.get(ref).scrollIntoView({ block: 'center' });
      } else {
        const s = scroller();
        const page = (s === document.scrollingElement ? innerHeight : s.clientHeight) * 0.85;
        if (direction === 'top') s.scrollTop = 0;
        else if (direction === 'bottom') s.scrollTop = s.scrollHeight;
        else s.scrollTop += direction === 'up' ? -page : page;
      }
      return C.info();
    };

    C.key = (key) => {
      const el = document.activeElement || document.body;
      if (key === 'Enter') { setTimeout(() => pressEnter(el), 0); return { target: C.ids.get(el) || el.localName }; }
      const codes = { Escape: 27, Tab: 9, Backspace: 8, Delete: 46, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
        PageUp: 33, PageDown: 34, Home: 36, End: 35, Space: 32 };
      const opts = { key: key === 'Space' ? ' ' : key, code: key, keyCode: codes[key] || 0, which: codes[key] || 0,
        bubbles: true, cancelable: true, composed: true };
      setTimeout(() => {
        const handled = !el.dispatchEvent(new KeyboardEvent('keydown', opts));
        el.dispatchEvent(new KeyboardEvent('keyup', opts));
        if (handled) return;
        if (key === 'Tab') {
          const focusable = Array.from(document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]'))
            .filter(e => e.tabIndex >= 0 && !e.disabled && e.getClientRects().length);
          const next = focusable[(focusable.indexOf(el) + 1) % focusable.length];
          next?.focus();
        } else if (key === 'PageDown' || key === 'PageUp' || key === 'Space') {
          if (!('value' in el)) C.scroll(key === 'PageUp' ? 'up' : 'down');
        }
      }, 0);
      return { target: C.ids.get(el) || el.localName };
    };

    /// Resolves once the DOM has been still for `idle` ms (or after `max` ms).
    C.quiet = (idle, max) => new Promise(resolve => {
      let timer;
      const done = () => { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); resolve(true); };
      const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, idle); });
      observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(done, idle);
      const cap = setTimeout(done, max);
    });
    })();
    """#
}
