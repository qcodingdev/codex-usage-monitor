#!/usr/bin/env node
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import readline from "node:readline";

const RETRY_DELAYS_MS = [750, 1_500, 3_000];

function resolveCodexPath() {
  const home = process.env.HOME || "";
  const candidates = [
    process.env.CODEX_BIN,
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    `${home}/Applications/ChatGPT.app/Contents/Resources/codex`,
    "/usr/local/bin/codex",
    "/opt/homebrew/bin/codex",
    `${home}/.local/bin/codex`,
    `${home}/.volta/bin/codex`,
    `${home}/.asdf/shims/codex`,
  ].filter(Boolean);
  const nvmRoot = `${home}/.nvm/versions/node`;
  try {
    for (const version of readdirSync(nvmRoot)) candidates.push(`${nvmRoot}/${version}/bin/codex`);
  } catch {
    // NVM is optional.
  }
  if (process.env.PATH) {
    for (const directory of process.env.PATH.split(":")) candidates.push(`${directory}/codex`);
  }
  try {
    const shellPath = execFileSync("/bin/zsh", ["-lc", "command -v codex 2>/dev/null"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (shellPath) candidates.push(shellPath);
  } catch {
    // A desktop-only installation may not have a shell command at all.
  }
  return candidates.find((candidate) => existsSync(candidate)) || null;
}

function readSnapshot(codexPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(codexPath, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "ignore"],
    });
    const pending = new Map();
    let nextId = 1;
    let settled = false;

    const timeout = setTimeout(() => finish(new Error("读取 Codex 用量超时")), 15_000);

    function send(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    }

    function request(method, params) {
      const id = nextId++;
      return new Promise((requestResolve, requestReject) => {
        pending.set(id, { resolve: requestResolve, reject: requestReject });
        send({ id, method, params });
      });
    }

    function finish(error, snapshot) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      child.kill("SIGTERM");
      if (error) reject(error);
      else resolve(snapshot);
    }

    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      try {
        const message = JSON.parse(line);
        if (message.id !== undefined && pending.has(message.id)) {
          const callback = pending.get(message.id);
          pending.delete(message.id);
          if (message.error) callback.reject(new Error(JSON.stringify(message.error)));
          else callback.resolve(message.result);
        }
      } catch {
        // Ignore non-protocol output.
      }
    });

    child.on("error", (error) => finish(error));
    child.on("exit", (code) => {
      if (!settled) finish(new Error(`Codex app-server 已退出（${code ?? "未知"}）`));
    });

    (async () => {
      try {
        await request("initialize", {
          clientInfo: { name: "codex-usage-monitor", version: "0.1.4" },
          capabilities: { experimentalApi: true },
        });
        send({ method: "initialized" });
        const [rateResponse, usageResponse] = await Promise.all([
          request("account/rateLimits/read", null),
          request("account/usage/read", null),
        ]);
        finish(null, makeSnapshot(rateResponse, usageResponse));
      } catch (error) {
        finish(error);
      }
    })();
  });
}

function remaining(window) {
  return Math.max(0, 100 - Number(window?.usedPercent || 0));
}

function resetText(epoch) {
  if (!epoch) return "未知";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(Number(epoch) * 1000));
}

function tokenText(value) {
  const number = Number(value || 0);
  if (number >= 1_000_000) return `${(number / 1_000_000).toFixed(1)}M`;
  if (number >= 1_000) return `${(number / 1_000).toFixed(1)}K`;
  return String(number);
}

function normalizeWindow(value) {
  if (!value) return null;
  return {
    remainingPercent: remaining(value),
    usedPercent: Number(value.usedPercent || 0),
    windowDurationMins: value.windowDurationMins || null,
    resetsAt: value.resetsAt || null,
  };
}

function makeSnapshot(rateResponse, usageResponse) {
  const rate = rateResponse.rateLimitsByLimitId?.codex || rateResponse.rateLimits || {};
  const windows = [normalizeWindow(rate.primary), normalizeWindow(rate.secondary)].filter(Boolean);
  const fiveHour = windows.find((window) => Number(window.windowDurationMins || 0) > 0 && Number(window.windowDurationMins) <= 720) || null;
  const sevenDay = windows.find((window) => Number(window.windowDurationMins || 0) >= 1440) || null;
  const fallbackFiveHour = fiveHour || (!sevenDay ? windows[0] || null : null);
  const fallbackSevenDay = sevenDay || (!fiveHour ? windows[1] || null : null);
  const todayKey = new Intl.DateTimeFormat("en-CA").format(new Date());
  const today = usageResponse.dailyUsageBuckets?.find((item) => item.startDate === todayKey)?.tokens || 0;
  return {
    plan: rate.planType || "unknown",
    fiveHour: fallbackFiveHour,
    sevenDay: fallbackSevenDay,
    primary: fallbackFiveHour,
    secondary: fallbackSevenDay,
    credits: rate.credits || null,
    todayTokens: Number(today),
    summary: usageResponse.summary || {},
    updatedAt: new Date().toISOString(),
  };
}

function printSnapshot(snapshot) {
  if (process.argv.includes("--json")) {
    process.stdout.write(`${JSON.stringify(snapshot, null, 2)}\n`);
    return;
  }

  const credits = snapshot.credits?.unlimited ? "无限" : (snapshot.credits?.balance || "0");
  process.stdout.write([
    `套餐：${snapshot.plan}`,
    `5 小时窗口：${snapshot.fiveHour ? `剩余 ${snapshot.fiveHour.remainingPercent}%（重置 ${resetText(snapshot.fiveHour.resetsAt)}）` : "暂无数据"}`,
    `7 天窗口：${snapshot.sevenDay ? `剩余 ${snapshot.sevenDay.remainingPercent}%（重置 ${resetText(snapshot.sevenDay.resetsAt)}）` : "暂无数据"}`,
    `Credits：${credits}`,
    `今日 Token：${tokenText(snapshot.todayTokens)}`,
    `累计 Token：${tokenText(snapshot.summary.lifetimeTokens)}`,
  ].join("\n") + "\n");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

const codexPath = resolveCodexPath();
if (!codexPath) {
  process.stderr.write("找不到 Codex app-server；已检查 CLI 和 ChatGPT.app\n");
  process.exit(1);
}

let lastError;
for (let attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt += 1) {
  try {
    const snapshot = await readSnapshot(codexPath);
    printSnapshot(snapshot);
    process.exit(0);
  } catch (error) {
    lastError = error;
    if (attempt < RETRY_DELAYS_MS.length) {
      await delay(RETRY_DELAYS_MS[attempt]);
    }
  }
}

process.stderr.write(`${lastError?.message || "读取 Codex 用量失败"}\n`);
process.exit(1);
