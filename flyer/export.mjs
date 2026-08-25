import { mkdir } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import QRCode from 'qrcode';
import { chromium } from 'playwright-core';

const flyerDir = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.join(flyerDir, 'assets');
const distDir = path.join(flyerDir, 'dist');
const qrUrl = 'https://daida-store.jp';

await mkdir(assetsDir, { recursive: true });
await mkdir(distDir, { recursive: true });
await QRCode.toFile(path.join(assetsDir, 'qr-code.png'), qrUrl, {
  errorCorrectionLevel: 'H',
  margin: 2,
  width: 900,
  color: { dark: '#002890', light: '#ffffff' },
});

const executableCandidates = [
  process.env.CHROME_PATH,
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].filter(Boolean);

let browser;
let lastError;
for (const executablePath of executableCandidates) {
  try {
    browser = await chromium.launch({ executablePath, headless: true });
    break;
  } catch (error) {
    lastError = error;
  }
}
if (!browser) throw new Error(`Chrome/Edgeを起動できませんでした。CHROME_PATHを指定してください。\n${lastError ?? ''}`);

try {
  for (const side of ['front', 'back']) {
    const context = await browser.newContext({ viewport: { width: 794, height: 1123 }, deviceScaleFactor: 3.125 });
    const page = await context.newPage();
    await page.goto(pathToFileURL(path.join(flyerDir, `${side}.html`)).href, { waitUntil: 'networkidle' });
    await page.emulateMedia({ media: 'print' });
    await page.screenshot({
      path: path.join(distDir, `daida-flyer-${side}.png`),
      clip: { x: 0, y: 0, width: 794, height: 1123 },
      scale: 'device',
    });
    await page.pdf({ path: path.join(distDir, `daida-flyer-${side}.pdf`), format: 'A4', printBackground: true, margin: { top: 0, right: 0, bottom: 0, left: 0 } });
    await context.close();
  }
} finally {
  await browser.close();
}

console.log(`Exported flyer files to ${distDir}`);
