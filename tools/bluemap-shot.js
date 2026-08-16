#!/usr/bin/env node
/*
 * bluemap-shot.js — 无头 Chrome 给 BlueMap 网页某个坐标截一张斜 45° 透视图。
 * 被 QQConsoleBridge 的 AI 工具 bluemap_shot 调用，也可手动跑来调相机参数。
 *
 * 用法:
 *   node tools/bluemap-shot.js --url "<BlueMap URL>" --out "<png路径>" \
 *        --chrome "<chrome.exe>" [--width 1000] [--height 600] [--wait 3000] \
 *        [--timeout 60000] [--keep 1] [--port 9222]
 *
 *   --keep 1  常驻一个无头 Chrome 复用（省每次冷启动 ~2-3s，代价是常驻 ~200MB 内存）。
 *             首次调用会拉起一个独立的后台 Chrome（绑定 --port 调试端口、独立 user-data-dir），
 *             之后的调用直接连上它；进程存活跨调用，node 退出不杀它。
 *
 * 依赖: puppeteer-core（复用系统已装的 Chrome/Edge，不额外下载浏览器）
 *   一次性安装:  cd tools && npm i puppeteer-core
 *
 * 退出码: 0 成功（png 已写出）; 非 0 失败（stderr 有原因）。
 */

const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

function parseArgs(argv) {
  const a = {};
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k.startsWith('--')) { a[k.slice(2)] = argv[i + 1]; i++; }
  }
  return a;
}

// 冷启动提速 + 软件 WebGL 兜底参数
function chromeArgs(width, height) {
  return [
    '--no-sandbox', '--disable-setuid-sandbox',
    '--hide-scrollbars', '--mute-audio',
    '--ignore-gpu-blocklist', '--enable-webgl',
    '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--disable-background-networking',
    '--disable-sync', '--disable-default-apps', '--metrics-recording-only',
    `--window-size=${width},${height}`,
  ];
}

async function endpointReady(port) {
  try {
    const r = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(1500) });
    if (!r.ok) return false;
    const j = await r.json();
    return !!j.webSocketDebuggerUrl;
  } catch { return false; }
}

// 常驻模式：连到已有 Chrome，没有就拉起一个独立后台 Chrome 再连
async function getKeepBrowser(puppeteer, chrome, port, width, height) {
  if (!(await endpointReady(port))) {
    if (!chrome) throw new Error('常驻模式需要 --chrome 指定 Chrome 路径');
    const udd = path.join(__dirname, 'tmp', 'chrome-bluemap');
    fs.mkdirSync(udd, { recursive: true });
    const args = ['--headless=new', `--remote-debugging-port=${port}`,
      `--user-data-dir=${udd}`, ...chromeArgs(width, height), 'about:blank'];
    const child = spawn(chrome, args, { detached: true, stdio: 'ignore' });
    child.unref(); // 脱离 node 生命周期，node 退出不杀它
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if (await endpointReady(port)) break;
      await new Promise((r) => setTimeout(r, 300));
    }
    if (!(await endpointReady(port))) throw new Error('常驻 Chrome 启动超时');
  }
  return puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: null });
}

async function main() {
  const a = parseArgs(process.argv);
  const url = a.url, out = a.out, chrome = a.chrome;
  const width = parseInt(a.width || '1000', 10);
  const height = parseInt(a.height || '600', 10);
  const waitMs = parseInt(a.wait || '3000', 10);
  const timeout = parseInt(a.timeout || '60000', 10);
  const keep = a.keep === '1' || a.keep === 'true';
  const port = parseInt(a.port || '9222', 10);

  if (!url || !out) { console.error('缺少 --url 或 --out'); process.exit(2); }

  let puppeteer;
  try { puppeteer = require('puppeteer-core'); }
  catch { console.error('未安装 puppeteer-core。请在 tools 目录执行一次: npm i puppeteer-core'); process.exit(3); }

  let browser, page;
  const keepMode = keep;
  try {
    if (keepMode) {
      browser = await getKeepBrowser(puppeteer, chrome, port, width, height);
    } else {
      browser = await puppeteer.launch({
        executablePath: chrome || undefined,
        headless: 'new',
        args: chromeArgs(width, height),
        defaultViewport: null,
      });
    }
    page = await browser.newPage();
    await page.setViewport({ width, height, deviceScaleFactor: 1 });
    await page.goto(url, { waitUntil: 'networkidle2', timeout });
    // BlueMap 流式加载瓦片的 WebGL 应用，networkidle 后再固定等一会儿让画面稳定
    await new Promise((r) => setTimeout(r, waitMs));
    await page.screenshot({ path: out, type: 'png', fullPage: false });
    console.error('OK ' + out);
  } finally {
    try { if (page) await page.close(); } catch {}
    // 常驻模式只断开连接、保活 Chrome；一次性模式关掉整个浏览器
    try {
      if (browser) { if (keepMode) await browser.disconnect(); else await browser.close(); }
    } catch {}
  }
  process.exit(0);
}

main().catch((e) => {
  console.error('截图失败: ' + (e && e.stack ? e.stack : e));
  process.exit(1);
});
