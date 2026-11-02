// Renders the icon artwork (App/Resources/*.svg) into the PNGs the asset catalog uses.
// Run after editing either SVG:   node scripts/render-icons.js
// Needs Playwright with Chromium (npm i -D playwright && npx playwright install chromium).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const assets = path.join(root, 'App/Resources/Assets.xcassets');

const jobs = [
  ...[16, 32, 64, 128, 256, 512, 1024].map((size) => ({
    svg: 'App/Resources/AppIcon.svg', size, out: `AppIcon.appiconset/icon_${size}.png`,
  })),
  // The logo shown inside the app (welcome guide, panel, settings).
  { svg: 'App/Resources/AppIcon.svg', size: 256, out: 'AppLogo.imageset/logo_256.png' },
  { svg: 'App/Resources/AppIcon.svg', size: 512, out: 'AppLogo.imageset/logo_512.png' },
  // Menu-bar glyph: 18 pt tall, 1x and 2x.
  { svg: 'App/Resources/MenuBarIcon.svg', size: 18, out: 'MenuBarIcon.imageset/menubar_18.png' },
  { svg: 'App/Resources/MenuBarIcon.svg', size: 36, out: 'MenuBarIcon.imageset/menubar_36.png' },
];

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (const job of jobs) {
    const svg = fs.readFileSync(path.join(root, job.svg), 'utf8');
    await page.setViewportSize({ width: job.size, height: job.size });
    await page.setContent(
      `<html><body style="margin:0;background:transparent">` +
      `<img src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}" ` +
      `style="width:${job.size}px;height:${job.size}px;display:block"></body></html>`
    );
    await page.waitForFunction(() => document.querySelector('img').complete);
    const out = path.join(assets, job.out);
    fs.mkdirSync(path.dirname(out), { recursive: true });
    await page.screenshot({ path: out, omitBackground: true });
    console.log('wrote', path.relative(root, out));
  }
  await browser.close();
})();
