#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { get } from "node:http";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

class Cdp {
  static async connect(url) {
    const socket = new WebSocket(url);
    await new Promise((resolveOpen, rejectOpen) => {
      socket.addEventListener("open", resolveOpen, { once: true });
      socket.addEventListener("error", rejectOpen, { once: true });
    });
    return new Cdp(socket);
  }

  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    socket.addEventListener("message", (event) => this.onMessage(event));
  }

  send(method, params = {}, timeoutMs = 10_000) {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolveSend, rejectSend) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectSend(new Error(`timeout waiting for CDP ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolveSend(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          rejectSend(error);
        },
      });
    });
  }

  waitForEvent(method, timeoutMs) {
    return new Promise((resolveEvent, rejectEvent) => {
      const timer = setTimeout(() => {
        cleanup();
        rejectEvent(new Error(`timeout waiting for ${method}`));
      }, timeoutMs);
      const handler = (params) => {
        cleanup();
        resolveEvent(params);
      };
      const cleanup = () => {
        clearTimeout(timer);
        const handlers = this.listeners.get(method) || [];
        this.listeners.set(method, handlers.filter((item) => item !== handler));
      };
      const handlers = this.listeners.get(method) || [];
      handlers.push(handler);
      this.listeners.set(method, handlers);
    });
  }

  async evaluate(expression) {
    const response = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    }, 15_000);
    if (response.exceptionDetails) {
      throw new Error(response.exceptionDetails.text || "Runtime.evaluate failed");
    }
    return response.result.value;
  }

  onMessage(event) {
    const message = JSON.parse(event.data);
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(message.error.message));
      } else {
        pending.resolve(message.result || {});
      }
      return;
    }
    const handlers = this.listeners.get(message.method) || [];
    for (const handler of handlers) {
      handler(message.params || {});
    }
  }

  close() {
    this.socket.close();
    return delay(50);
  }
}

const root = resolve(".");
let baseUrl = "";
const pageFilters = [];
const viewports = [
  { name: "mobile", width: 390, height: 844 },
  { name: "desktop", width: 1280, height: 720 },
];

for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === "--base-url") {
    baseUrl = process.argv[++i] || "";
  } else if (arg === "--page") {
    pageFilters.push((process.argv[++i] || "").replace(/^\/+/, ""));
  } else if (arg === "-h" || arg === "--help") {
    usage(0);
  } else {
    console.error(`unknown arg: ${arg}`);
    usage(2);
  }
}

if (!baseUrl) {
  console.error("error: --base-url is required");
  usage(2);
}
baseUrl = baseUrl.replace(/\/+$/, "");

if (typeof WebSocket !== "function") {
  console.log("skip: Node.js runtime has no WebSocket support for responsive check");
  process.exit(0);
}

const chrome = findChrome();
if (!chrome) {
  console.log("skip: Chrome/Chromium not found for responsive check");
  process.exit(0);
}

let htmlPages = (await walk(root))
  .filter((path) => path.endsWith(".html"))
  .map((path) => relative(root, path).split("/").join("/"))
  .sort();

if (pageFilters.length > 0) {
  const filterSet = new Set(pageFilters);
  htmlPages = htmlPages.filter((page) => filterSet.has(page));
  if (htmlPages.length === 0) {
    console.error(`error: --page did not match any HTML file: ${pageFilters.join(", ")}`);
    process.exit(2);
  }
  const missing = pageFilters.filter((page) => !htmlPages.includes(page));
  if (missing.length > 0) {
    console.error(`error: --page did not match HTML file(s): ${missing.join(", ")}`);
    process.exit(2);
  }
}

if (htmlPages.length === 0) {
  console.log("skip: no HTML pages for responsive check");
  process.exit(0);
}

const debuggingPort = await getFreePort();
const profileDir = await mkdtemp(join(tmpdir(), "mitoujr-responsive-chrome."));
const chromeProcess = spawn(chrome, [
  "--headless=new",
  "--disable-background-networking",
  "--disable-default-apps",
  "--disable-extensions",
  "--disable-gpu",
  "--disable-sync",
  "--hide-scrollbars",
  "--no-first-run",
  `--remote-debugging-port=${debuggingPort}`,
  `--user-data-dir=${profileDir}`,
  "about:blank",
], {
  stdio: ["ignore", "ignore", "pipe"],
});

let chromeExited = false;
let stderr = "";
chromeProcess.once("exit", () => {
  chromeExited = true;
});
chromeProcess.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

let cdp;
try {
  const pageTarget = await waitForPageTarget(debuggingPort, 10_000);
  cdp = await Cdp.connect(pageTarget.webSocketDebuggerUrl);
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");

  const failures = [];
  pageLoop:
  for (const page of htmlPages) {
    for (const viewport of viewports) {
      const url = `${baseUrl}/${page}`;
      let result;
      try {
        result = await checkPage(cdp, url, viewport);
      } catch (error) {
        const checkError = error.message || String(error);
        failures.push({ page, viewport: viewport.name, checkError });
        if (checkError.includes("timeout waiting for CDP")) {
          break pageLoop;
        }
        continue;
      }
      if (result.overflowX || result.imageProblems.length > 0 || result.overflowingElements.length > 0) {
        failures.push({ page, viewport: viewport.name, ...result });
      }
    }
  }

  if (failures.length > 0) {
    for (const failure of failures) {
      console.error(`responsive check failed: ${failure.page} @ ${failure.viewport}`);
      if (failure.checkError) {
        console.error(`  error: ${failure.checkError}`);
        continue;
      }
      console.error(`  viewport: ${failure.clientWidth}px, scrollWidth: ${failure.scrollWidth}px`);
      if (failure.imageProblems.length > 0) {
        console.error(`  image problems: ${JSON.stringify(failure.imageProblems.slice(0, 5))}`);
      }
      if (failure.overflowingElements.length > 0) {
        console.error(`  overflowing elements: ${JSON.stringify(failure.overflowingElements.slice(0, 5))}`);
      }
    }
    process.exitCode = 1;
  } else {
    console.log(`ok: responsive check passed for ${htmlPages.length} HTML pages at ${viewports.length} viewport(s)`);
  }
} finally {
  if (cdp) {
    await cdp.close().catch(() => {});
  }
  if (!chromeExited) {
    chromeProcess.kill();
    await waitForProcessExit(chromeProcess, () => chromeExited, 5_000).catch(async () => {
      chromeProcess.kill("SIGKILL");
      await waitForProcessExit(chromeProcess, () => chromeExited, 5_000).catch(() => {});
    });
  }
  await rm(profileDir, { recursive: true, force: true });
  if (process.exitCode && stderr.trim()) {
    console.error(stderr.trim().split("\n").slice(-12).join("\n"));
  }
}

function usage(code) {
  const out = code === 0 ? console.log : console.error;
  out(`usage: scripts/check-responsive.mjs --base-url http://127.0.0.1:<port> [--page tech/example.html]

Uses local Chrome/Chromium headless to check every HTML page at mobile and
desktop viewport widths for horizontal overflow and missing images. If Chrome
is not available, the check prints a skip message and exits successfully.
Repeat --page to check a subset while debugging.`);
  process.exit(code);
}

function findChrome() {
  const env = process.env.CHROME || process.env.CHROMIUM;
  const candidates = [
    env,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/opt/homebrew/bin/google-chrome",
    "/opt/homebrew/bin/chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  return candidates.find((path) => existsSync(path)) || "";
}

async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const paths = [];
  for (const entry of entries) {
    if (entry.name === ".git" || entry.name === "node_modules") continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      paths.push(...await walk(path));
    } else {
      paths.push(path);
    }
  }
  return paths;
}

function getFreePort() {
  return new Promise((resolvePort, rejectPort) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => resolvePort(address.port));
    });
    server.on("error", rejectPort);
  });
}

async function waitForPageTarget(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const targets = await httpJson(`http://127.0.0.1:${port}/json`);
      const page = targets.find((target) => target.type === "page" && target.webSocketDebuggerUrl);
      if (page) return page;
    } catch (error) {
      lastError = error;
    }
    await delay(100);
  }
  throw new Error(`Chrome DevTools did not become ready: ${lastError?.message || "timeout"}`);
}

function httpJson(url) {
  return new Promise((resolveJson, rejectJson) => {
    get(url, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          rejectJson(new Error(`HTTP ${response.statusCode}`));
          return;
        }
        try {
          resolveJson(JSON.parse(body));
        } catch (error) {
          rejectJson(error);
        }
      });
    }).on("error", rejectJson);
  });
}

async function checkPage(cdp, url, viewport) {
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: viewport.width,
    height: viewport.height,
    deviceScaleFactor: 1,
    mobile: viewport.width < 700,
  });

  const load = cdp.waitForEvent("Page.loadEventFired", 10_000);
  await cdp.send("Page.navigate", { url });
  await load;
  await cdp.evaluate(`new Promise((resolve) => {
    const maxY = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
    const step = Math.max(260, Math.floor(window.innerHeight * 0.8));
    let y = 0;
    const tick = () => {
      window.scrollTo(0, y);
      y += step;
      if (y <= maxY + step) {
        setTimeout(tick, 35);
      } else {
        window.scrollTo(0, 0);
        setTimeout(resolve, 160);
      }
    };
    tick();
  })`);

  return await cdp.evaluate(`(() => {
    const doc = document.documentElement;
    const overflowingElements = [];
    for (const el of Array.from(document.body.querySelectorAll("*"))) {
      const rect = el.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const style = getComputedStyle(el);
      if (style.position === "fixed" || style.visibility === "hidden" || style.display === "none") continue;
      if (rect.right > doc.clientWidth + 1 || rect.left < -1) {
        overflowingElements.push({
          tag: el.tagName.toLowerCase(),
          className: String(el.className || "").slice(0, 80),
          text: String(el.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 100),
          left: Math.round(rect.left),
          right: Math.round(rect.right),
          width: Math.round(rect.width)
        });
      }
      if (overflowingElements.length >= 8) break;
    }
    const imageProblems = Array.from(document.querySelectorAll("img"))
      .filter((img) => !img.complete || img.naturalWidth === 0)
      .map((img) => ({ src: img.getAttribute("src"), alt: img.getAttribute("alt") || "" }));
    return {
      title: document.title,
      clientWidth: doc.clientWidth,
      scrollWidth: doc.scrollWidth,
      overflowX: doc.scrollWidth > doc.clientWidth + 1,
      imageProblems,
      overflowingElements
    };
  })()`);
}

function delay(ms) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}

function withTimeout(promise, timeoutMs, message) {
  let timer;
  const timeout = new Promise((_, rejectTimeout) => {
    timer = setTimeout(() => rejectTimeout(new Error(message)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function waitForProcessExit(process, isExited, timeoutMs) {
  if (isExited()) return Promise.resolve();
  return withTimeout(
    new Promise((resolveDone) => process.once("exit", resolveDone)),
    timeoutMs,
    "process did not exit in time",
  );
}
