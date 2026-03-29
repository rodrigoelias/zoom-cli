#!/usr/bin/env ts-node
/**
 * Phase 2: API Discovery via Network Sniffing
 * 
 * Usage:
 *   npm run sniff-api
 * 
 * This script:
 * 1. Loads your captured cookies
 * 2. Opens Zoom.us in a browser with cookies pre-loaded
 * 3. Intercepts all network requests (XHR/fetch)
 * 4. Logs endpoints, headers, payloads, and responses
 * 5. Generates a discovery report (api-discovery.json)
 * 
 * IMPORTANT: You must manually navigate and perform actions
 * (view meeting list, schedule meeting, join meeting, etc.)
 * while the sniffer captures the API calls.
 */

import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

const ZOOM_URL = 'https://zoom.us';
const COOKIES_DIR = path.join(process.cwd(), '.cookies');
const RAW_COOKIES_FILE = path.join(COOKIES_DIR, '.raw_cookies');
const API_DISCOVERY_FILE = path.join(process.cwd(), 'docs', 'api-discovery.json');
const REQUEST_LOG_FILE = path.join(process.cwd(), 'docs', 'captured-requests.jsonl');

interface CapturedRequest {
  timestamp: string;
  method: string;
  url: string;
  headers: Record<string, string>;
  postData?: string;
  responseStatus?: number;
  responseBody?: string;
  resourceType: string;
}

let capturedRequests: CapturedRequest[] = [];

async function main() {
  console.log('🔍 Zoom API Discovery via Network Sniffing\n');

  // Check if cookies exist
  if (!fs.existsSync(RAW_COOKIES_FILE)) {
    console.error('❌ No cookies found!');
    console.error(`   Run: npm run capture-cookies`);
    process.exit(1);
  }

  // Load cookies
  const rawCookieString = fs.readFileSync(RAW_COOKIES_FILE, 'utf8');
  console.log(`📝 Loaded cookies from ${RAW_COOKIES_FILE}\n`);

  const browser = await chromium.launch({ 
    headless: false,
    args: ['--disable-blink-features=AutomationControlled']
  });

  try {
    const context = await browser.newContext({
      // Pre-load cookies so we stay logged in
      extraHTTPHeaders: {
        'Cookie': rawCookieString,
      }
    });

    const page = await context.newPage();

    // Intercept all network requests
    page.on('request', (request) => {
      const resourceType = request.resourceType();
      const url = request.url();

      // Log XHR/fetch/API calls (filter out images, fonts, etc.)
      if (resourceType === 'xhr' || resourceType === 'fetch' || url.includes('/rest/') || url.includes('/api/')) {
        const captured: CapturedRequest = {
          timestamp: new Date().toISOString(),
          method: request.method(),
          url: url,
          headers: request.headers(),
          postData: request.postData() || undefined,
          resourceType: resourceType,
        };

        console.log(`\n📡 ${request.method()} ${url}`);
        console.log(`   Headers: ${JSON.stringify(captured.headers, null, 2)}`);
        if (captured.postData) {
          console.log(`   Body: ${captured.postData}`);
        }

        capturedRequests.push(captured);
      }
    });

    // Intercept responses to capture status and body
    page.on('response', async (response) => {
      const resourceType = response.request().resourceType();
      const url = response.url();

      if (resourceType === 'xhr' || resourceType === 'fetch' || url.includes('/rest/') || url.includes('/api/')) {
        try {
          const body = await response.text();
          const request = capturedRequests.find(r => r.url === url);
          
          if (request) {
            request.responseStatus = response.status();
            request.responseBody = body.substring(0, 500); // First 500 chars
            console.log(`   Response: ${response.status()}`);
          }
        } catch (e) {
          // Response body might not be readable (e.g., binary)
        }
      }
    });

    console.log('🌐 Opening zoom.us...\n');
    await page.goto(ZOOM_URL, { waitUntil: 'networkidle' });

    console.log('📋 Now perform these actions (API calls will be captured):');
    console.log('   1. Navigate to your meetings list');
    console.log('   2. Click on a meeting to view details');
    console.log('   3. Try to schedule a new meeting (don\'t submit)');
    console.log('   4. View participant list if available');
    console.log('   5. Check meeting settings\n');
    console.log('   (Press Ctrl+C when done)\n');

    // Keep the page open for manual interaction
    await new Promise(resolve => {
      process.on('SIGINT', () => {
        console.log('\n\n✅ Capturing complete!');
        resolve(true);
      });
    });

    // Save discovery report
    const docs = path.dirname(API_DISCOVERY_FILE);
    if (!fs.existsSync(docs)) {
      fs.mkdirSync(docs, { recursive: true });
    }

    // Analyze captured requests to build endpoint catalog
    const endpoints = analyzeEndpoints(capturedRequests);

    fs.writeFileSync(
      API_DISCOVERY_FILE,
      JSON.stringify(
        {
          capturedAt: new Date().toISOString(),
          totalRequests: capturedRequests.length,
          endpoints: endpoints,
          rawRequests: capturedRequests,
        },
        null,
        2
      ),
      'utf8'
    );

    // Also save as JSONL (one request per line) for easier processing
    fs.writeFileSync(
      REQUEST_LOG_FILE,
      capturedRequests.map(r => JSON.stringify(r)).join('\n'),
      'utf8'
    );

    console.log(`\n📝 Saved API discovery: ${API_DISCOVERY_FILE}`);
    console.log(`📝 Saved request log: ${REQUEST_LOG_FILE}\n`);

    console.log('📊 Discovered Endpoints:');
    for (const endpoint of endpoints) {
      console.log(`   ${endpoint.method} ${endpoint.path}`);
    }

    console.log('\n📌 Next steps:');
    console.log('   1. Review docs/api-discovery.json');
    console.log('   2. Run: npm run build');
    console.log('   3. Implement CLI commands based on discovered endpoints\n');

    process.exit(0);
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  } finally {
    await browser.close();
  }
}

interface EndpointInfo {
  path: string;
  method: string;
  count: number;
  lastSeen: string;
}

function analyzeEndpoints(requests: CapturedRequest[]): EndpointInfo[] {
  const endpoints = new Map<string, EndpointInfo>();

  for (const req of requests) {
    // Extract path from URL (remove query params)
    const url = new URL(req.url);
    const path = url.pathname;
    const key = `${req.method} ${path}`;

    if (endpoints.has(key)) {
      const ep = endpoints.get(key)!;
      ep.count++;
      ep.lastSeen = req.timestamp;
    } else {
      endpoints.set(key, {
        path,
        method: req.method,
        count: 1,
        lastSeen: req.timestamp,
      });
    }
  }

  return Array.from(endpoints.values()).sort((a, b) => b.count - a.count);
}

main();
