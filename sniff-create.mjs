#!/usr/bin/env node
/**
 * sniff-create.mjs — Open the Zoom meeting schedule page and capture
 * the form submission to understand all available fields.
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
  const cookies = rawCookies.split("; ").map((pair) => {
    const [name, ...rest] = pair.split("=");
    return { name: name.trim(), value: rest.join("="), domain: ".zoom.us", path: "/" };
  });

  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext({
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
  });
  await context.addCookies(cookies);
  const page = await context.newPage();

  // Capture form submissions
  page.on("request", (req) => {
    const url = req.url();
    if (url.includes("/meeting/") && req.method() === "POST") {
      console.log(`\n📡 POST ${url}`);
      console.log(`   Content-Type: ${req.headers()["content-type"]}`);
      const body = req.postData();
      if (body) {
        console.log(`\n   Raw body (${body.length} chars):\n`);
        // Parse URL-encoded form
        const params = new URLSearchParams(body);
        for (const [k, v] of params.entries()) {
          console.log(`   ${k} = ${v}`);
        }
        writeFileSync(join(__dirname, ".create_form_data.txt"), body, "utf-8");
        console.log(`\n   💾 Saved to .create_form_data.txt`);
      }
    }
  });

  console.log(`\n🌐 Opening schedule page — fill out the form manually, then submit.`);
  console.log(`   The script will capture all form fields.\n`);
  console.log(`   TIP: Set up a recurring weekly Saturday meeting with an invitee,`);
  console.log(`   then click Save. The script will log everything.\n`);

  await page.goto(`${ZOOM_BASE}/meeting/schedule`, { waitUntil: "networkidle", timeout: 30000 });

  // Keep browser open for 5 minutes for manual interaction
  console.log("⏳ Waiting up to 5 minutes for you to fill and submit the form...\n");
  await page.waitForTimeout(300000);

  await browser.close();
}

main().catch((err) => {
  console.error("Fatal:", err.message);
  process.exit(1);
});
