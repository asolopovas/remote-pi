// Offline regression checks. Supply jsdom 29.1.1 from isolated tooling via
// NODE_PATH, then run from cockpit/: node --test test/md_preview_security.cjs
// No network/resources or page scripts are enabled; this is not a WebView test.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const { JSDOM } = require('jsdom');
const assets = path.resolve(__dirname, '../assets/md_preview');

function preview() {
  const dom = new JSDOM('<!doctype html><div id="content"></div>', {
    runScripts: 'outside-only',
  });
  for (const file of ['markdown-it.min.js', 'purify.min.js', 'morphdom-umd.min.js', 'preview.js']) {
    dom.window.eval(readFileSync(path.join(assets, file), 'utf8'));
  }
  assert.equal(dom.window.DOMPurify.isSupported, true);
  return dom;
}

test('unchanged preview API renders markdown, frontmatter, images and updates', () => {
  const dom = preview();
  try {
    const { window: w } = dom;
    w.__cockpit.setContent('---\ntitle: "<img src=x onerror=bad()>"\n---\n# Heading\n\n**bold** and https://example.com\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n```js\nconst x = 1;\n```\n\n![relative](images/a.png)\n\n<details open><summary>More</summary>body</details>', '/docs');
    const root = w.document.getElementById('content');
    assert.equal(root.querySelector('h1').textContent, 'Heading');
    assert.equal(root.querySelector('strong').textContent, 'bold');
    assert.equal(root.querySelector('a').href, 'https://example.com/');
    assert.equal(root.querySelectorAll('table').length, 2);
    assert.match(root.querySelector('code.language-js').textContent, /const x = 1/);
    assert.equal(root.querySelector('img').getAttribute('src'), 'ckp-res://local/%2Fdocs%2Fimages%2Fa.png');
    assert.equal(root.querySelector('.ckp-frontmatter td').textContent, '<img src=x onerror=bad()>');
    assert.equal(root.querySelector('.ckp-frontmatter img'), null);
    assert.equal(root.querySelector('details').hasAttribute('open'), true);
    w.__cockpit.setTheme({ '--preview-test': 'red' });
    assert.equal(w.document.documentElement.style.getPropertyValue('--preview-test'), 'red');
    w.__cockpit.setContent('# Updated', '/docs');
    assert.equal(w.document.querySelector('#content h1').textContent, 'Updated');
    assert.equal(w.document.querySelector('#content img'), null);
  } finally { dom.window.close(); }
});

test('preview string/allowlist path strips executable markup and unsafe protocols', () => {
  const dom = preview();
  try {
    const w = dom.window;
    w.__cockpit.setContent('<script>alert(1)</script>\n\n<img src=x onerror="alert(1)"><a href="javascript:alert(1)" onclick="bad()">bad</a><a href="unknown:payload">unknown</a><svg onload="bad()"></svg><iframe srcdoc="bad"></iframe><style>body{display:none}</style><form><button>bad</button></form><input type=checkbox checked disabled><details open><summary>ok</summary></details>');
    const root = w.document.getElementById('content');
    assert.equal(root.querySelector('script, svg, iframe, style, form, button, [onerror], [onclick], [onload], [srcdoc]'), null);
    for (const a of root.querySelectorAll('a')) assert.equal(a.hasAttribute('href'), false);
    assert.equal(root.querySelector('input').hasAttribute('checked'), true);
    assert.equal(root.querySelector('input').hasAttribute('disabled'), true);
    assert.equal(root.querySelector('summary').textContent, 'ok');
  } finally { dom.window.close(); }
});

test('GHSA-6688-9rhm-gjv2: removed rawtext IN_PLACE root fails closed', () => {
  const dom = preview();
  try {
    const w = dom.window;
    const style = w.document.createElement('style');
    style.setAttribute('onclick', 'bad()');
    style.textContent = '</style><img src=x onerror=bad()>';
    w.document.body.appendChild(style);
    assert.throws(() => w.DOMPurify.sanitize(style, { IN_PLACE: true }), { name: 'TypeError' });
  } finally { dom.window.close(); }
});

for (const hook of ['afterSanitizeElements', 'afterSanitizeAttributes']) {
  test(`GHSA-p98j-92pf-mc4p: ${hook} detached subtree is neutralized`, () => {
    const dom = preview();
    try {
      const w = dom.window;
      const root = w.document.createElement('div');
      root.innerHTML = '<section id="wrap"><img src=x onerror="bad()"></section>';
      w.document.body.appendChild(root);
      const wrap = root.firstChild;
      const img = wrap.firstChild;
      w.DOMPurify.addHook(hook, node => { if (node === wrap) node.remove(); });
      w.DOMPurify.sanitize(root, { IN_PLACE: true });
      assert.equal(wrap.parentNode, null);
      assert.equal(img.hasAttribute('onerror'), false);
    } finally { dom.window.close(); }
  });
}

// Bound the actual advisory payloads in separate processes, including failure
// termination. The generous timeout is a regression tripwire, not a benchmark.
for (const payload of ['emails', 'schemes']) {
  test(`GHSA-253c-mchw-3w2r: bounded linkify ${payload}`, () => {
    const script = `
      const assert = require('node:assert/strict');
      const md = require(${JSON.stringify(path.join(assets, 'markdown-it.min.js'))})({ html: true, linkify: true, typographer: false });
      const html = md.render(${payload === 'emails' ? "'a@b.co\\n'" : "'a://'"}.repeat(20000));
      ${payload === 'emails' ? "assert.equal((html.match(/mailto:/g) || []).length, 20000);" : "assert.equal(html.includes('<a '), false); assert.ok(html.includes('a://'));"}
    `;
    const result = spawnSync(process.execPath, ['-e', script], { timeout: 10000, encoding: 'utf8' });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
  });
}
