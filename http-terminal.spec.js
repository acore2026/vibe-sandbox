const { test, expect } = require('@playwright/test');

test('plain terminal handles typing and backspace without leaking control text', async ({ page }) => {
  await page.goto('http://127.0.0.1:7901/');
  const terminal = page.locator('#plain-terminal');
  await expect(terminal).toBeVisible();
  await expect(terminal).toContainText('coder@vibe-sandbox');

  await terminal.click();
  await page.keyboard.type('abc');
  await page.keyboard.press('Backspace');
  await page.keyboard.type('d');
  await page.keyboard.press('Enter');

  await expect(terminal).toContainText('abd');
  await expect(terminal).not.toContainText('[K');
  await expect(terminal).not.toContainText('abc');
});
