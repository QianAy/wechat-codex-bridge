// 微信测试公众号 → Claude Code AI 桥接系统
// 云队列服务 —— 部署到 Render.com 或其他 Node.js 云平台
//
// 核心功能:
//   /wechat - 微信 webhook 接入点
//   /api/poll - 本地PC代理轮询取任务
//   /api/result - 本地PC代理回传执行结果
//   /health - 健康检查

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// ==================== 配置 ====================

const PORT = Number(process.env.PORT || 8788);
const WECHAT_TOKEN = process.env.WECHAT_TOKEN || "";
const AGENT_SECRET = process.env.WECHAT_AGENT_SECRET || "";
const OWNER_OPENID = process.env.WECHAT_OWNER_OPENID || "";
const AUTO_BIND_OWNER = process.env.WECHAT_AUTO_BIND_OWNER === "1";

// 持久化文件路径
const DATA_FILE = path.join(__dirname, "queue-data.json");

// 速率限制: 每个 OpenID 每分钟最多 10 条消息
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX = 10;

// 任务过期时间: 超过 1 小时未处理的任务自动清理
const TASK_EXPIRY_MS = 3_600_000;

// ==================== 状态变量 ====================

let boundOwner = OWNER_OPENID;
let nextId = 1;
let tasks = [];
let results = [];

// 速率限制记录: { openid: [timestamp, ...] }
const rateLimitMap = new Map();

// ==================== 持久化 ====================

// 从磁盘恢复数据
function loadData() {
  try {
    if (fs.existsSync(DATA_FILE)) {
      const raw = fs.readFileSync(DATA_FILE, "utf8");
      const data = JSON.parse(raw);
      nextId = data.nextId || 1;
      tasks = data.tasks || [];
      results = data.results || [];
      boundOwner = data.boundOwner || OWNER_OPENID;
      console.log(`[持久化] 已恢复: ${tasks.length} 个待处理任务, ${results.length} 条结果, 绑定用户: ${boundOwner || "(未绑定)"}`);
    }
  } catch (err) {
    console.error("[持久化] 恢复数据失败:", err.message);
  }
}

// 将数据写入磁盘
function saveData() {
  try {
    const data = { nextId, tasks, results, boundOwner };
    fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2), "utf8");
  } catch (err) {
    console.error("[持久化] 保存数据失败:", err.message);
  }
}

// ==================== 工具函数 ====================

function sha1(text) {
  return crypto.createHash("sha1").update(text).digest("hex");
}

// 验证微信签名
function verifyWechat(url) {
  const signature = url.searchParams.get("signature");
  const timestamp = url.searchParams.get("timestamp");
  const nonce = url.searchParams.get("nonce");
  if (!signature || !timestamp || !nonce || !WECHAT_TOKEN) return false;
  const expected = sha1([WECHAT_TOKEN, timestamp, nonce].sort().join(""));
  return expected === signature;
}

// 从 XML 中提取文本内容
function xmlText(xml, tag) {
  const match = xml.match(new RegExp(`<${tag}><!\\[CDATA\\[([\\s\\S]*?)\\]\\]><\\/${tag}>|<${tag}>([\\s\\S]*?)<\\/${tag}>`));
  return match ? (match[1] || match[2] || "").trim() : "";
}

// 构建微信回复 XML
// 关键：Content 必须用 CDATA 包裹，否则中文、换行、特殊符号会导致微信解析失败
function wechatReply(to, from, content) {
  const now = Math.floor(Date.now() / 1000);
  // CDATA 内只需处理 ]]> 序列，其余字符（中文、换行、代码等）均可安全传递
  const safeContent = String(content).replace(/]]>/g, "]]]]><![CDATA[>");
  return `<xml>
<ToUserName><![CDATA[${to}]]></ToUserName>
<FromUserName><![CDATA[${from}]]></FromUserName>
<CreateTime>${now}</CreateTime>
<MsgType><![CDATA[text]]></MsgType>
<Content><![CDATA[${safeContent}]]></Content>
</xml>`;
}

// 读取请求体
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// 返回 JSON 响应
function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

// 等待指定任务的结果返回（用于快速轮询）
function waitForResult(taskId, timeoutMs) {
  const start = Date.now();
  return new Promise((resolve) => {
    function check() {
      const r = results.find((r) => r.id === taskId);
      if (r) {
        resolve(r.result);
      } else if (Date.now() - start > timeoutMs) {
        resolve(null);
      } else {
        setTimeout(check, 500);
      }
    }
    check();
  });
}

// 验证本地代理请求
function authorizedAgent(req, url) {
  const bearer = req.headers.authorization || "";
  const querySecret = url.searchParams.get("secret") || "";
  return AGENT_SECRET && (bearer === `Bearer ${AGENT_SECRET}` || querySecret === AGENT_SECRET);
}

// 检查速率限制
function checkRateLimit(openid) {
  const now = Date.now();
  let timestamps = rateLimitMap.get(openid);
  if (!timestamps) {
    timestamps = [];
    rateLimitMap.set(openid, timestamps);
  }
  // 清理过期的记录
  const windowStart = now - RATE_LIMIT_WINDOW_MS;
  const recent = timestamps.filter((t) => t > windowStart);
  rateLimitMap.set(openid, recent);
  if (recent.length >= RATE_LIMIT_MAX) return false;
  recent.push(now);
  return true;
}

// 清理过期任务
function cleanExpiredTasks() {
  const cutoff = new Date(Date.now() - TASK_EXPIRY_MS).toISOString();
  const before = tasks.length;
  tasks = tasks.filter((t) => t.createdAt > cutoff);
  const removed = before - tasks.length;
  if (removed > 0) {
    console.log(`[清理] 移除 ${removed} 个过期任务`);
    saveData();
  }
}

// 日志输出 (带时间戳)
function log(level, message) {
  const ts = new Date().toISOString();
  console.log(`[${ts}] [${level}] ${message}`);
}

// ==================== HTTP 服务器 ====================

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

  try {
    // ---- 健康检查 ----
    if (url.pathname === "/health") {
      return json(res, 200, {
        ok: true,
        uptime: process.uptime(),
        queued: tasks.length,
        results: results.length,
        ownerBound: Boolean(boundOwner),
        memoryMB: Math.round(process.memoryUsage().heapUsed / 1024 / 1024),
        persistence: fs.existsSync(DATA_FILE) ? "ok" : "none",
      });
    }

    // ---- 微信 Webhook ----
    if (url.pathname === "/wechat") {
      // 签名验证
      if (!verifyWechat(url)) {
        log("WARN", "微信签名验证失败");
        res.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
        return res.end("bad signature");
      }

      // GET 请求: 微信服务器配置验证
      if (req.method === "GET") {
        res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
        return res.end(url.searchParams.get("echostr") || "");
      }

      // 只接受 POST 请求
      if (req.method !== "POST") {
        res.writeHead(405);
        return res.end();
      }

      const body = await readBody(req);
      const from = xmlText(body, "FromUserName");
      const to = xmlText(body, "ToUserName");
      const type = xmlText(body, "MsgType");
      const content = xmlText(body, "Content");

      log("INFO", `微信消息: from=${from} type=${type} content="${content.slice(0, 50)}"`);

      // 自动绑定第一个发送者
      if (!boundOwner && AUTO_BIND_OWNER && from) {
        boundOwner = from;
        log("INFO", `已自动绑定用户: ${from}`);
        saveData();
      }

      // 权限检查
      if (boundOwner && from !== boundOwner) {
        log("WARN", `未授权用户尝试访问: ${from}`);
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, "未授权的用户，请联系管理员。"));
      }

      // 只支持文本消息
      if (type !== "text") {
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, "目前只支持文本消息。"));
      }

      // 速率限制
      if (!checkRateLimit(from)) {
        log("WARN", `速率限制触发: ${from}`);
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, "发送太快，请稍后再试。"));
      }

      // ---- 帮助 / 帮助 ----
      if (/^(help|帮助)$/i.test(content)) {
        const helpMsg = [
          "可用命令:",
          "ask <问题> / 问答 <问题>  → AI 问答",
          "dev <项目> <需求> / 需求 <项目> <需求>  → AI 开发",
          "review <项目> / 审查 <项目>  → 代码审查",
          "git status <项目> / git状态 <项目>  → 查看状态",
          "git diff <项目> / git差异 <项目>  → 查看差异",
          "git commit <项目> <说明> / git提交 <项目> <说明>  → 提交代码",
          "confirm <id>  → 确认待处理操作",
          "status / 状态  → 系统状态",
          "log / 日志  → 最近日志",
          "result / 结果  → 查看最近执行结果",
        ].join("\n");
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, helpMsg));
      }

      // ---- 结果 / result ----
      if (/^(result|结果)$/i.test(content)) {
        if (results.length === 0) {
          // 没有结果时，检查是否有待处理任务，给出更具体的提示
          if (tasks.length > 0) {
            res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
            return res.end(wechatReply(from, to, `AI 仍在思考中...当前有 ${tasks.length} 个任务等待处理，请稍后再发送"结果"查看。`));
          }
          res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
          return res.end(wechatReply(from, to, "暂无任务记录。直接发送问题即可开始对话。"));
        }
        // 只返回最新一条结果，不带历史
        const latest = results[results.length - 1];
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, `#${latest.id} ${latest.result}`.slice(0, 1800)));
      }

      // ---- 其他命令: 入队 ----
      const task = {
        id: String(nextId++),
        message: content,
        from,
        createdAt: new Date().toISOString(),
      };
      tasks.push(task);
      saveData();
      log("INFO", `任务入队: #${task.id} "${content.slice(0, 80)}"`);

      // 快速轮询：等待最多4秒，看代理是否已处理完成
      // 简单命令（如时间、目录）通常1-2秒内返回，无需额外发"结果"
      const quickResult = await waitForResult(task.id, 4000);
      if (quickResult) {
        log("INFO", `快速返回: #${task.id}`);
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, quickResult.slice(0, 1800)));
      }

      // AI任务等耗时操作，根据类型给出预计等待时间
      const isQuickCmd = /^(time|时间|ls|目录|status|状态|log|日志|whoami|用户|ip|help|帮助|result|结果|git\b)/i.test(content);
      const isDevCmd = /^(dev |需求 |review |审查 |git commit |git提交 )/i.test(content);
      let waitHint;
      if (isDevCmd) {
        waitHint = "预计需要 1-5 分钟。完成后发送\"结果\"查看。";
      } else if (!isQuickCmd) {
        // 自然语言问题 → AI 问答
        waitHint = "AI 思考中，预计 30-120 秒。请稍后发送\"结果\"查看。";
      } else {
        waitHint = "正在处理，请稍后发送\"结果\"查看。";
      }

      res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
      return res.end(wechatReply(from, to, `已入队 #${task.id}\n${waitHint}`));
    }

    // ---- 代理轮询取任务 ----
    if (url.pathname === "/api/poll") {
      if (!authorizedAgent(req, url)) return json(res, 403, { error: "forbidden" });
      const task = tasks.shift() || null;
      if (task) {
        log("INFO", `任务出队: #${task.id} 分配给代理`);
        saveData();
      }
      return json(res, 200, task || {});
    }

    // ---- 代理回传结果 ----
    if (url.pathname === "/api/result") {
      if (!authorizedAgent(req, url)) return json(res, 403, { error: "forbidden" });
      if (req.method !== "POST") return json(res, 405, { error: "method not allowed" });
      const body = JSON.parse((await readBody(req)) || "{}");
      results.push({
        id: String(body.id || ""),
        result: String(body.result || ""),
        createdAt: new Date().toISOString(),
      });
      // 只保留最近 50 条结果
      while (results.length > 50) results.shift();
      saveData();
      log("INFO", `结果已保存: #${body.id}`);
      return json(res, 200, { ok: true });
    }

    // ---- 404 ----
    return json(res, 404, { error: "not found" });
  } catch (err) {
    log("ERROR", err.message);
    return json(res, 500, { error: err.message });
  }
});

// ==================== 启动 ====================

if (!WECHAT_TOKEN) {
  console.error("错误: 未设置 WECHAT_TOKEN 环境变量");
  console.error("请设置后重启，例如: $env:WECHAT_TOKEN='your-token'; node cloud-wechat-queue.js");
  process.exit(1);
}
if (!AGENT_SECRET) {
  console.error("错误: 未设置 WECHAT_AGENT_SECRET 环境变量");
  console.error("请设置后重启，例如: $env:WECHAT_AGENT_SECRET='your-secret'; node cloud-wechat-queue.js");
  process.exit(1);
}

// 启动时恢复数据
loadData();

// 每 10 分钟清理一次过期任务
setInterval(cleanExpiredTasks, 600_000);

server.listen(PORT, () => {
  log("INFO", `云队列服务已启动，端口: ${PORT}`);
  log("INFO", `微信接入点: /wechat`);
  log("INFO", `健康检查: /health`);
  log("INFO", `当前队列: ${tasks.length} 个任务, ${results.length} 条结果`);
  if (boundOwner) {
    log("INFO", `已绑定用户: ${boundOwner}`);
  } else if (AUTO_BIND_OWNER) {
    log("INFO", "等待用户首次发送消息以自动绑定...");
  }
});
