#!/usr/bin/env node
/**
 * grab-cookies.mjs — Open Zoom in a real browser, let the user do SSO,
 * then capture session cookies and save them for zoom-cli.sh.
 *
 * Usage:  node grab-cookies.mjs
 */

import { chromium } from "playwright";
import { writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RAW_COOKIE_FILE = join(__dirname, ".raw_cookies");
const ZOOM_BASE = "https://skyscanner.zoom.us";

async function main() {
  console.log("\n🌐  Opening Zoom in Chromium — please sign in.\n");
  console.log("    The browser will close automatically once cookies are captured.\n");

  const browser = await chromium.launch({
    headless: false,          // must be visible for SSO
    args: ["--disable-blink-features=AutomationControlled"],
  });

  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
  });

  const page = await context.newPage();

  // Navigate to meeting list — will redirect through SSO if not logged in
  await page.goto(`${ZOOM_BASE}/meeting`, { waitUntil: "domcontentloaded" });

  // Wait until we land back on a zoom.us page (post-SSO)
  console.log("⏳  Waiting for SSO to complete...\n");

  try {
    await page.waitForURL(/skyscanner\.zoom\.us(?!\/saml)/, {
      timeout: 120_000,   // 2 min for SSO
    });
  } catch {
    // Log where we actually ended up
    console.error(`❌  Timed out waiting for login. Current URL: ${page.url()}`);
    console.error("    Try again.");
    await browser.close();
    process.exit(1);
  }

  // Give the page a moment to set all cookies
  await page.waitForTimeout(2000);

  // Grab all cookies for the zoom.us domain
  const cookies = await context.cookies(ZOOM_BASE);

  if (cookies.length === 0) {
    console.error("❌  No cookies captured.");
    await browser.close();
    process.exit(1);
  }

  // Build raw cookie string: "name=value; name2=value2"
  const raw = cookies.map((c) => `${c.name}=${c.value}`).join("; ");

  writeFileSync(RAW_COOKIE_FILE, raw, "utf-8");
  console.log(`✅  Captured ${cookies.length} cookies → ${RAW_COOKIE_FILE}`);

  // Also save Netscape format for reference
  const netscape = [
    "# Netscape HTTP Cookie File",
    `# Captured ${new Date().toISOString()}`,
    ...cookies.map((c) => {
      const domain = c.domain.startsWith(".") ? c.domain : `.${c.domain}`;
      const flag = domain.startsWith(".") ? "TRUE" : "FALSE";
      const secure = c.secure ? "TRUE" : "FALSE";
      const expiry = c.expires > 0 ? Math.floor(c.expires) : "0";
      return `${domain}\t${flag}\t${c.path}\t${secure}\t${expiry}\t${c.name}\t${c.value}`;
    }),
  ].join("\n");

  writeFileSync(join(__dirname, "cookies.txt"), netscape, "utf-8");
  console.log(`✅  Also saved Netscape format → cookies.txt`);

  await browser.close();

  console.log("\n🎯  Next steps:");
  console.log("    ./zoom-cli.sh refresh-csrf");
  console.log("    ./zoom-cli.sh list\n");
}

main().catch((err) => {
  console.error("Fatal:", err.message);
  process.exit(1);
});
