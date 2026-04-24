const { chromium } = require('/usr/lib/node_modules/@playwright/cli/node_modules/playwright-core');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.goto('http://127.0.0.1:7901/');
  await page.waitForSelector('#plain-terminal', { state: 'visible' });
  await page.waitForFunction(() => document.querySelector('#plain-terminal').textContent.includes('coder@vibe-sandbox'));

  const terminal = page.locator('#plain-terminal');
  await terminal.click();
  await page.keyboard.type('abc');
  await page.keyboard.press('Backspace');
  await page.keyboard.type('d');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1000);

  const text = await terminal.textContent();
  console.log(text);

  const failures = [];
  if (!text.includes('abd')) failures.push('expected edited command/output to contain abd');
  if (text.includes('[K')) failures.push('terminal leaked [K control text');
  if (text.includes('abc')) failures.push('backspace did not remove c from abc');
  if (text.includes('\u0000')) failures.push('terminal leaked NUL placeholder characters');

  await browser.close();

  if (failures.length) {
    console.error(failures.join('\n'));
    process.exit(1);
  }
})();
