// Applies the brand Den pushed into the realm (rendered by footer.ftl as
// #cs-brand) to the login page: name, tagline, logo, colours, favicon.
// Without it the neutral defaults from css/conservices.css stay.
(function () {
  function hexToHsl(v) {
    if (typeof v !== 'string') return null;
    var h = v.trim().replace(/^#/, '');
    if (h.length === 3) h = h.replace(/./g, '$&$&');
    if (!/^[0-9a-f]{6}$/i.test(h)) return null;
    var r = parseInt(h.slice(0, 2), 16) / 255;
    var g = parseInt(h.slice(2, 4), 16) / 255;
    var b = parseInt(h.slice(4, 6), 16) / 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    var l = (max + min) / 2, s = 0, hue = 0;
    if (max !== min) {
      var d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      hue = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
      hue *= 60;
    }
    return [Math.round(hue), Math.round(s * 100), Math.round(l * 100)];
  }
  function hsl(c) { return 'hsl(' + c[0] + ' ' + c[1] + '% ' + c[2] + '%)'; }
  function clamp(n, lo, hi) { return Math.min(hi, Math.max(lo, n)); }

  /** Readable text colour on top of an HSL colour. */
  function onColor(c) {
    var h = c[0], s = c[1] / 100, l = c[2] / 100;
    var a = s * Math.min(l, 1 - l);
    function f(n) {
      var k = (n + h / 30) % 12;
      return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    }
    function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    var lum = 0.2126 * lin(f(0)) + 0.7152 * lin(f(8)) + 0.0722 * lin(f(4));
    return lum > 0.45 ? '#18181b' : '#ffffff';
  }

  function applyColours(theme) {
    var root = document.documentElement.style;
    var p = hexToHsl(theme.primary);
    if (p) {
      root.setProperty('--cs-primary', hsl(p));
      root.setProperty('--cs-primary-fg', onColor(p));
      var hover = hexToHsl(theme.primary_hover) || [p[0], p[1], clamp(p[2] - 7, 5, 95)];
      root.setProperty('--cs-primary-hover', hsl(hover));
      // Dark mode only takes the hue, lightened so it stays readable.
      var dark = [p[0], p[1], clamp(p[2], 55, 75)];
      root.setProperty('--cs-primary-dark', hsl(dark));
      root.setProperty('--cs-primary-dark-fg', onColor(dark));
      root.setProperty('--cs-primary-dark-hover', hsl([p[0], p[1], clamp(dark[2] + 6, 0, 85)]));
    }
  }

  function applyHeader(b) {
    var header = document.getElementById('kc-header-wrapper');
    if (!header) return;
    var name = (b.organization_name || '').trim();
    var tagline = (b.tagline || '').trim();
    if (!name && !b.logo_url) return;
    header.textContent = '';
    if (b.logo_url) {
      var img = document.createElement('img');
      img.className = 'cs-logo';
      img.alt = name;
      img.src = b.logo_url;
      header.appendChild(img);
    }
    if (name) {
      var title = document.createElement('span');
      title.textContent = name;
      header.appendChild(title);
    }
    if (tagline) {
      var sub = document.createElement('span');
      sub.className = 'cs-tagline';
      sub.textContent = tagline;
      header.appendChild(sub);
    }
  }

  function applyFavicon(b) {
    if (!b.favicon_url) return;
    var link = document.querySelector('link[rel="icon"]') || document.createElement('link');
    link.rel = 'icon';
    link.href = b.favicon_url;
    document.head.appendChild(link);
  }

  function apply() {
    var el = document.getElementById('cs-brand');
    if (!el) return;
    var b;
    try {
      b = JSON.parse(el.getAttribute('data-brand') || '');
    } catch (e) {
      return;
    }
    if (!b || typeof b !== 'object') return;
    applyColours(b.theme || {});
    applyHeader(b);
    applyFavicon(b);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply);
  else apply();
})();
