#!/usr/bin/env ts-node
/**
 * Phase 1: Session Capture via Okta SSO
 * 
 * Usage:
 *   npm run capture-cookies
 * 
 * This script:
 * 1. Opens Zoom.us in a visible browser (headless=false for SSO)
 * 2. Waits for you to complete Okta login (SSO + MFA)
 * 3. Captures all cookies (including httpOnly)
 * 4. Saves them in both raw and Netscape formats
 * 
 * Critical: context.cookies() captures httpOnly cookies.
 * document.cookie (JS) cannot access these — we MUST use Playwright.
 */

import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

const ZOOM_URL = 'https://zoom.us/web/sso/login?en=signin#/sso';
const ZOOM_DOMAIN = 'zoom.us';
const COOKIES_DIR = path.join(process.cwd(), '.cookies');
const RAW_COOKIES_FILE = path.join(COOKIES_DIR, '.raw_cookies');
const NETSCAPE_COOKIES_FILE = path.join(COOKIES_DIR, 'cookies.txt');

interface CookieData {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number;
  httpOnly: boolean;
  secure: boolean;
  sameSite: string;
}

async function main() {
  console.log('🔐 Zoom Cookie Capture via Okta SSO\n');
  console.log('📋 Steps:');
  console.log('  1. A browser will open to zoom.us');
  console.log('  2. You will be redirected to Okta login');
  console.log('  3. Complete SSO + MFA (if required)');
  console.log('  4. Once logged in, this script will capture cookies\n');

  // Create cookies directory
  if (!fs.existsSync(COOKIES_DIR)) {
    fs.mkdirSync(COOKIES_DIR, { recursive: true });
  }

  const browser = await chromium.launch({ 
    headless: false,  // MUST be visible for SSO/MFA
    args: [
      '--disable-blink-features=AutomationControlled',  // Avoid bot detection
    ]
  });

  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    console.log('🌐 Opening Zoom SSO login...\n');
    await page.goto(ZOOM_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });

    // Wait for Okta redirect flow to complete
    // The pattern: zoom.us → okta (login) → zoom.us (authenticated)
    // We wait for a URL that's NOT a login/SSO intermediary
    console.log('⏳ Waiting for Okta login to complete...');
    console.log('   (This will timeout if you don\'t log in within 5 minutes)\n');

    try {
      await page.waitForURL(
        /https:\/\/skyscanner\.zoom\.us\/meeting/,
        { timeout: 5 * 60 * 1000 }  // 5 minutes
      );
    } catch (e) {
      console.error('❌ Login timeout or navigation error');
      console.error('   Make sure you complete the Okta SSO flow');
      process.exit(1);
    }

    // Give cookies time to settle
    console.log('✅ Login detected. Waiting for cookies to settle...');
    await page.waitForTimeout(3000);

    // Wait for authenticated session cookies to be present
    console.log('⏳ Waiting for authenticated session cookies...');
    let cookies = await context.cookies();
    let attempts = 0;
    while (!cookies.some(c => c.name.includes('zoom_us_sid') || c.name.includes('zm_jwt')) && attempts < 10) {
      await page.waitForTimeout(1000);
      cookies = await context.cookies();
      attempts++;
    }

    // Capture cookies (includes httpOnly!)
    const finalCookies = await context.cookies();
    
    if (finalCookies.length === 0) {
      console.error('❌ No cookies found! This might mean:');
      console.error('   - Login failed');
      console.error('   - Cookies are blocked');
      process.exit(1);
    }

    console.log(`✅ Captured ${finalCookies.length} cookies\n`);

    // Format 1: Raw cookie string (for curl/HTTP headers)
    const rawCookieString = finalCookies
      .map(c => `${c.name}=${c.value}`)
      .join('; ');

    fs.writeFileSync(RAW_COOKIES_FILE, rawCookieString, 'utf8');
    console.log(`📝 Saved raw cookies: ${RAW_COOKIES_FILE}`);
    console.log(`   Format: name1=value1; name2=value2; ...\n`);

    // Format 2: Netscape format (importable into curl, wget, etc.)
    const netscapeCookies = formatNetscapeCookies(finalCookies);
    fs.writeFileSync(NETSCAPE_COOKIES_FILE, netscapeCookies, 'utf8');
    console.log(`📝 Saved Netscape format: ${NETSCAPE_COOKIES_FILE}\n`);

    // Display important cookies
    console.log('🔑 Important cookies found:');
    const importantCookies = ['zoom_us_sid', 'zoom_us_ppid', 'zm_jwt', 'zm_authenticator'];
    for (const name of importantCookies) {
      const cookie = finalCookies.find(c => c.name === name || c.name.includes(name));
      if (cookie) {
        const value = cookie.value.substring(0, 30) + (cookie.value.length > 30 ? '...' : '');
        console.log(`   ✓ ${cookie.name}: ${value}`);
      }
    }

    console.log('\n📌 Next steps:');
    console.log('   1. Run: npm run sniff-api');
    console.log('      (This will discover Zoom API endpoints)');
    console.log('   2. Cookies will auto-refresh when needed\n');

    process.exit(0);
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  } finally {
    await browser.close();
  }
}

/**
 * Convert Playwright cookies to Netscape format
 * Format: domain, flag, path, secure, expiry, name, value
 */
function formatNetscapeCookies(cookies: any[]): string {
  const lines = [
    '# Netscape HTTP Cookie File',
    '# This file is generated by zoom-cli grab-cookies script',
    '# Do not edit manually\n',
  ];

  for (const cookie of cookies) {
    const httponly = cookie.httpOnly ? '#HttpOnly_' : '';
    const domain = cookie.domain.startsWith('.') ? cookie.domain : '.' + cookie.domain;
    const flag = cookie.domain.startsWith('.') ? 'TRUE' : 'FALSE';
    const secure = cookie.secure ? 'TRUE' : 'FALSE';
    const expiry = cookie.expires ? Math.floor(cookie.expires * 1000) : '0';

    lines.push(
      `${httponly}${domain}\t${flag}\t${cookie.path}\t${secure}\t${expiry}\t${cookie.name}\t${cookie.value}`
    );
  }

  return lines.join('\n');
}

main();
