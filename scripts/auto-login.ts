#!/usr/bin/env ts-node
/**
 * Automated Headless Login via Okta SSO
 * 
 * Usage:
 *   OKTA_USERNAME=user@example.com OKTA_PASSWORD=password npm run auto-login
 * 
 * This script:
 * 1. Reads Okta credentials from environment variables
 * 2. Opens Zoom.us in headless mode
 * 3. Automatically completes Okta login flow
 * 4. Captures cookies after successful login
 * 5. Saves them for use with other scripts
 */

import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

const ZOOM_URL = 'https://zoom.us';
const COOKIES_DIR = path.join(process.cwd(), '.cookies');
const RAW_COOKIES_FILE = path.join(COOKIES_DIR, '.raw_cookies');
const NETSCAPE_COOKIES_FILE = path.join(COOKIES_DIR, 'cookies.txt');

// Get credentials from environment (optional)
const OKTA_USERNAME = process.env.OKTA_USERNAME;
const OKTA_PASSWORD = process.env.OKTA_PASSWORD;

async function main() {
  console.log('🔐 Zoom Cookie Capture\n');

  // First, try headless mode to check if already authenticated
  console.log('🔍 Checking authentication status (headless)...');
  let isAuthenticated = await checkAuthenticationHeadless();

  let headlessMode = true;

  if (!isAuthenticated) {
    console.log('\n❌ Not authenticated with Okta\n');
    
    if (OKTA_USERNAME && OKTA_PASSWORD) {
      console.log(`👤 Attempting automated login with credentials...\n`);
      headlessMode = true;
    } else {
      console.log('📖 Opening browser for manual Okta SSO login...\n');
      console.log('📋 Steps:');
      console.log('   1. Browser will open to zoom.us');
      console.log('   2. Complete the Okta SSO flow');
      console.log('   3. Script will capture cookies once you\'re logged in\n');
      headlessMode = false;
    }
  } else {
    console.log('✅ Already authenticated with Okta (using headless mode)\n');
    headlessMode = true;
  }

  const browser = await chromium.launch({ 
    headless: headlessMode,
    args: ['--disable-blink-features=AutomationControlled']
  });

  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    // Listen for console messages to debug
    page.on('console', msg => {
      if (msg.type() === 'error') {
        console.log(`   [Browser Error] ${msg.text()}`);
      }
    });

    console.log(`🌐 Opening authenticated meeting dashboard${headlessMode ? ' (headless)' : ' (visible browser)'}...`);
    await page.goto('https://skyscanner.zoom.us/meeting', { waitUntil: 'networkidle', timeout: 30000 });

    // Check if we're logged in now
    const loggedInNow = await checkIfLoggedIn(page);
    
    if (!loggedInNow && !headlessMode) {
      // Manual browser mode - wait for user to login
      console.log('⏳ Waiting for you to complete Okta SSO (timeout: 5 minutes)...\n');
      try {
        await page.waitForURL(/zoom\.us/, { timeout: 5 * 60 * 1000 });
        console.log('✅ Login detected!\n');
      } catch (e) {
        console.error('❌ Login timeout. Please complete the Okta SSO flow.');
        process.exit(1);
      }
    } else if (!loggedInNow && headlessMode) {
      // Headless mode but not authenticated - try automated login with credentials
      if (OKTA_USERNAME && OKTA_PASSWORD) {
        console.log('🔄 Completing automated SSO login...\n');

        // Wait for redirect to Okta
        await page.waitForURL(/okta|login/, { timeout: 10000 }).catch(() => {
          console.log('   (No immediate redirect detected, checking for login form...)');
        });

        // Try to find and fill login form
        console.log('📝 Looking for login form...');
        
        // Wait for username field
        const usernameFieldSelector = 'input[type="email"], input[name="username"], input[id="okta-signin-username"], input[placeholder*="email" i], input[placeholder*="username" i]';
        
        try {
          await page.waitForSelector(usernameFieldSelector, { timeout: 5000 });
          console.log('   Found username field');
          
          // Fill username
          await page.fill(usernameFieldSelector, OKTA_USERNAME);
          console.log(`   ✓ Entered username: ${OKTA_USERNAME}`);
        } catch (e) {
          console.log('   ⚠ Could not find username field, trying password...');
        }

        // Try to find and fill password field
        const passwordFieldSelector = 'input[type="password"], input[name="password"], input[id="okta-signin-password"]';
        
        try {
          await page.waitForSelector(passwordFieldSelector, { timeout: 5000 });
          console.log('   Found password field');
          
          // Fill password
          await page.fill(passwordFieldSelector, OKTA_PASSWORD);
          console.log(`   ✓ Entered password`);
        } catch (e) {
          console.log('   ⚠ Could not find password field');
        }

        // Look for sign-in button
        console.log('   Looking for sign-in button...');
        const signInButton = await page.$('button:has-text("Sign In"), button:has-text("submit"), input[type="submit"]');
        
        if (signInButton) {
          console.log('   Found sign-in button, clicking...');
          await signInButton.click();
          
          // Wait for redirect back to Zoom after successful login
          console.log('   ⏳ Waiting for redirect after login...\n');
          try {
            await page.waitForURL(/zoom\.us/, { timeout: 15000 });
            console.log('   ✅ Redirected back to Zoom!');
          } catch (e) {
            console.log('   ⚠ Redirect timeout (may need MFA)');
          }
        } else {
          console.error('   ❌ Could not find sign-in button');
        }

        // Wait for any MFA if needed
        console.log('   ⏳ Waiting for page to fully load (including MFA if needed)...');
        await page.waitForTimeout(3000);
      } else {
        console.error('❌ Not authenticated and no credentials provided');
        console.error('   Provide credentials: OKTA_USERNAME=user@example.com OKTA_PASSWORD=pass npm run auto-login');
        process.exit(1);
      }
    } else {
      console.log('✅ Authenticated!\n');
    }

    // Double-check we're at the meeting dashboard
    const currentUrl = page.url();
    console.log(`\n📍 Current URL: ${currentUrl}`);
    
    if (!currentUrl.includes('skyscanner.zoom.us') && !currentUrl.includes('meeting')) {
      console.log('⚠️  Warning: Not on authenticated meeting page - cookies may not be valid for API calls');
    }
    console.log();

    // Capture cookies
    const cookies = await context.cookies();
    
    if (cookies.length === 0) {
      console.error('❌ No cookies found!');
      process.exit(1);
    }

    console.log(`🍪 Captured ${cookies.length} cookies\n`);

    // Create cookies directory if needed
    if (!fs.existsSync(COOKIES_DIR)) {
      fs.mkdirSync(COOKIES_DIR, { recursive: true });
    }

    // Format 1: Raw cookie string
    const rawCookieString = cookies
      .map(c => `${c.name}=${c.value}`)
      .join('; ');

    fs.writeFileSync(RAW_COOKIES_FILE, rawCookieString, 'utf8');
    console.log(`📝 Saved raw cookies: ${RAW_COOKIES_FILE}`);

    // Format 2: Netscape format
    const netscapeCookies = formatNetscapeCookies(cookies);
    fs.writeFileSync(NETSCAPE_COOKIES_FILE, netscapeCookies, 'utf8');
    console.log(`📝 Saved Netscape format: ${NETSCAPE_COOKIES_FILE}\n`);

    // Show important cookies
    console.log('🔑 Important cookies:');
    const importantCookies = ['zoom_us_sid', 'zoom_us_ppid', 'zm_jwt', 'zm_authenticator', '_zm_ssid'];
    for (const name of importantCookies) {
      const cookie = cookies.find(c => c.name === name);
      if (cookie) {
        const value = cookie.value.substring(0, 30) + (cookie.value.length > 30 ? '...' : '');
        console.log(`   ✓ ${cookie.name}: ${value}`);
      }
    }

    console.log('\n✅ Headless login complete!');
    console.log('   Cookies ready for: npm run refresh-cookies, npm run sniff-api\n');

    process.exit(0);

  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  } finally {
    await browser.close();
  }
}

/**
 * Quick headless check: are we authenticated? (30 second timeout)
 */
async function checkAuthenticationHeadless(): Promise<boolean> {
  const browser = await chromium.launch({ 
    headless: true,
    args: ['--disable-blink-features=AutomationControlled']
  });

  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    await page.goto(ZOOM_URL, { waitUntil: 'networkidle', timeout: 20000 });
    const isLoggedIn = await checkIfLoggedIn(page);
    
    return isLoggedIn;
  } catch (e) {
    return false;
  } finally {
    await browser.close();
  }
}

/**
 * Check if already logged in to Zoom
 */
async function checkIfLoggedIn(page: any): Promise<boolean> {
  try {
    // Look for elements that only appear when logged in
    const loggedInIndicators = [
      'text=My Meetings',
      'text=Schedule',
      'text=Join',
      '[data-testid="user-menu"]',
      'a[href*="/meeting"]',
    ];

    for (const selector of loggedInIndicators) {
      const element = await page.$(selector).catch(() => null);
      if (element) {
        return true;
      }
    }

    return false;
  } catch (e) {
    return false;
  }
}

/**
 * Convert Playwright cookies to Netscape format
 */
function formatNetscapeCookies(cookies: any[]): string {
  const lines = [
    '# Netscape HTTP Cookie File',
    '# This file is generated by zoom-cli auto-login script',
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
