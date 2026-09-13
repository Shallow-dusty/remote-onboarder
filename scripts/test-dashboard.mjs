// Optional browser validation. Pass a package.json with @playwright/test
// installed; no extra framework or runtime dependency is added to the receiver.
import { createRequire } from 'node:module';
import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const require = createRequire(process.argv[2] || import.meta.url);
const { chromium, expect } = require('@playwright/test');
const html = await readFile(new URL('../log-receiver/dashboard.html', import.meta.url), 'utf8');
const output = fileURLToPath(new URL('../build/audit/dashboard/', import.meta.url));
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  let records = [], fail = false;
  await page.route('http://onboarder.test/**', async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/') return route.fulfill({ contentType: 'text/html', body: html });
    if (fail) return route.fulfill({ status: 503, body: 'unavailable' });
    if (path === '/sessions') return route.fulfill({ contentType: 'application/json', body: JSON.stringify(records) });
    return route.fulfill({ contentType: 'application/x-ndjson', body: JSON.stringify({ timestamp: '2026-09-13T00:00:00Z', level: 'INFO', step: 'preflight', message: '<script>window.injected=true</script> fixture only' })+'\n' });
  });
  await page.goto('http://onboarder.test/');
  await expect(page.locator('#sessions')).toContainText('还没有接入记录');
  records = [{ sessionId: 'fixture-computer-001', updatedAt: '2026-09-13T00:00:00Z', bytes: 1024 }];
  await page.locator('#refresh').click();
  await page.getByRole('button', { name: /fixture-computer-001/ }).click();
  await expect(page.locator('#log')).toContainText('fixture only');
  assert.equal(await page.evaluate(() => window.injected), undefined);
  await page.screenshot({ path: output+'desktop.png', fullPage: true });
  await page.locator('#pause').click();
  await expect(page.locator('#pause')).toHaveAttribute('aria-pressed', 'true');
  await page.locator('#follow').uncheck();
  fail = true;
  await page.locator('#refresh').click();
  await expect(page.locator('#status')).toContainText('同步失败');
  await expect(page.locator('#log')).toContainText('fixture only');
  await page.setViewportSize({ width: 360, height: 800 });
  await page.screenshot({ path: output+'narrow-error.png', fullPage: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.locator('#search').fill('not-found');
  await expect(page.locator('#sessions')).toContainText('没有匹配');
  console.log('Dashboard browser checks PASS: empty, selected, escaped text, pause, error retention, search, narrow viewport');
} finally { await browser.close(); }
