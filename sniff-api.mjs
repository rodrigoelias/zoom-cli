#!/usr/bin/env node
/**
 * sniff-api.mjs — Open Zoom meeting page and capture all XHR/fetch calls
 * to understand the real API the Vue SPA uses.
 *
 * Usage:  node sniff-api.mjs
 */

import { chromium } from "playwright";
import { readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RAW_COOKIE_FILE = join(__dirname, ".raw_cookies");
const ZOOM_BASE = "https://skyscanner.zoom.us";

async function main() {
  const rawCookies = readFileSync(RAW_COOKIE_FILE, "utf-8");

  // Parse raw cookie string into Playwright cookie objects
  const cookies = rawCookies.split("; ").map((pair) => {
    const [name, ...rest] = pair.split("=");
    return {
      name: name.trim(),
      value: rest.join("="),
      domain: ".zoom.us",
      path: "/",
    };
  });

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
  });

  await context.addCookies(cookies);

  const page = await context.newPage();

  // Capture all API requests
  const apiCalls = [];

  page.on("request", (req) => {
    const url = req.url();
    if (
      url.includes("/rest/") ||
      url.includes("/api/") ||
      (url.includes("zoom.us") && req.resourceType() === "xhr") ||
      (url.includes("zoom.us") && req.resourceType() === "fetch")
    ) {
      apiCalls.push({
        method: req.method(),
        url: url,
        headers: req.headers(),
        postData: req.postData() || null,
        resourceType: req.resourceType(),
      });
    }
  });

  page.on("response", async (res) => {
    const url = res.url();
    if (url.includes("/rest/") || url.includes("/wc/") || url.includes("/api/")) {
      const call = apiCalls.find((c) => c.url === url);
      if (call) {
        call.status = res.status();
        try {
          const text = await res.text();
          call.responsePreview = text.substring(0, 500);
        } catch {}
      }
    }
  });

  console.log(`\n🔍  Loading ${ZOOM_BASE}/meeting and sniffing API calls...\n`);

  try {
    await page.goto(`${ZOOM_BASE}/meeting`, {
      waitUntil: "networkidle",
      timeout: 30000,
    });
  } catch (e) {
    console.log(`⚠️  Page load: ${e.message}`);
  }

  // Wait a bit for any lazy-loaded XHR
  await page.waitForTimeout(3000);

  console.log(`📡  Captured ${apiCalls.length} API calls:\n`);

  for (const call of apiCalls) {
    console.log(`  ${call.method} ${call.url}`);
    if (call.status) console.log(`    Status: ${call.status}`);
    if (call.postData) console.log(`    Body: ${call.postData.substring(0, 200)}`);
    if (call.responsePreview)
      console.log(`    Response: ${call.responsePreview.substring(0, 200)}`);
    console.log();
  }

  // Save full details
  writeFileSync(
    join(__dirname, ".api_calls.json"),
    JSON.stringify(apiCalls, null, 2),
    "utf-8"
  );
  console.log(`💾  Full details saved to .api_calls.json`);

  // Also grab the final page URL to check for redirects
  console.log(`\n📍  Final URL: ${page.url()}`);
  console.log(`📄  Title: ${await page.title()}`);

  await browser.close();
}

main().catch((err) => {
  console.error("Fatal:", err.message);
  process.exit(1);
});
