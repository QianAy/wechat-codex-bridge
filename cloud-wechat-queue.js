const http = require("http");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 8788);
const WECHAT_TOKEN = process.env.WECHAT_TOKEN || "";
const AGENT_SECRET = process.env.WECHAT_AGENT_SECRET || "";
const OWNER_OPENID = process.env.WECHAT_OWNER_OPENID || "";
const AUTO_BIND_OWNER = process.env.WECHAT_AUTO_BIND_OWNER === "1";

let boundOwner = OWNER_OPENID;
let nextId = 1;
const tasks = [];
const results = [];

function sha1(text) {
  return crypto.createHash("sha1").update(text).digest("hex");
}

function verifyWechat(url) {
  const signature = url.searchParams.get("signature");
  const timestamp = url.searchParams.get("timestamp");
  const nonce = url.searchParams.get("nonce");
  if (!signature || !timestamp || !nonce || !WECHAT_TOKEN) return false;
  const expected = sha1([WECHAT_TOKEN, timestamp, nonce].sort().join(""));
  return expected === signature;
}

function xmlText(xml, tag) {
  const match = xml.match(new RegExp(`<${tag}><!\\[CDATA\\[([\\s\\S]*?)\\]\\]><\\/${tag}>|<${tag}>([\\s\\S]*?)<\\/${tag}>`));
  return match ? (match[1] || match[2] || "").trim() : "";
}

function escapeXml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function wechatReply(to, from, content) {
  const now = Math.floor(Date.now() / 1000);
  const safeContent = escapeXml(content);
  return `<xml>
<ToUserName><![CDATA[${to}]]></ToUserName>
<FromUserName><![CDATA[${from}]]></FromUserName>
<CreateTime>${now}</CreateTime>
<MsgType><![CDATA[text]]></MsgType>
<Content>${safeContent}</Content>
</xml>`;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", chunk => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body)
  });
  res.end(body);
}

function authorizedAgent(req, url) {
  const bearer = req.headers.authorization || "";
  const querySecret = url.searchParams.get("secret") || "";
  return AGENT_SECRET && (bearer === `Bearer ${AGENT_SECRET}` || querySecret === AGENT_SECRET);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

  try {
    if (url.pathname === "/health") {
      return json(res, 200, { ok: true, queued: tasks.length, results: results.length, ownerBound: Boolean(boundOwner) });
    }

    if (url.pathname === "/wechat") {
      if (!verifyWechat(url)) {
        res.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
        return res.end("bad signature");
      }

      if (req.method === "GET") {
        res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
        return res.end(url.searchParams.get("echostr") || "");
      }

      if (req.method !== "POST") {
        res.writeHead(405);
        return res.end();
      }

      const body = await readBody(req);
      const from = xmlText(body, "FromUserName");
      const to = xmlText(body, "ToUserName");
      const type = xmlText(body, "MsgType");
      const content = xmlText(body, "Content");

      if (!boundOwner && AUTO_BIND_OWNER && from) boundOwner = from;
      if (boundOwner && from !== boundOwner) {
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, "This sender is not authorized."));
      }

      if (type !== "text") {
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, "Only text messages are supported."));
      }

      if (/^(help|帮助)$/i.test(content)) {
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, "Send a whitelisted command. Send result to read the latest execution result."));
      }

      if (/^(result|结果)$/i.test(content)) {
        const latest = results.slice(-3).reverse().map(r => `#${r.id} ${r.result}`).join("\n\n") || "No results yet.";
        res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
        return res.end(wechatReply(from, to, latest.slice(0, 1800)));
      }

      const task = {
        id: String(nextId++),
        message: content,
        from,
        createdAt: new Date().toISOString()
      };
      tasks.push(task);

      res.writeHead(200, { "content-type": "application/xml; charset=utf-8" });
      return res.end(wechatReply(from, to, `Queued #${task.id}. Send result later to read output.`));
    }

    if (url.pathname === "/api/poll") {
      if (!authorizedAgent(req, url)) return json(res, 403, { error: "forbidden" });
      const task = tasks.shift() || null;
      return json(res, 200, task || {});
    }

    if (url.pathname === "/api/result") {
      if (!authorizedAgent(req, url)) return json(res, 403, { error: "forbidden" });
      if (req.method !== "POST") return json(res, 405, { error: "method not allowed" });
      const body = JSON.parse(await readBody(req) || "{}");
      results.push({
        id: String(body.id || ""),
        result: String(body.result || ""),
        createdAt: new Date().toISOString()
      });
      while (results.length > 20) results.shift();
      return json(res, 200, { ok: true });
    }

    return json(res, 404, { error: "not found" });
  } catch (err) {
    return json(res, 500, { error: err.message });
  }
});

if (!WECHAT_TOKEN) {
  console.error("Missing WECHAT_TOKEN");
  process.exit(1);
}
if (!AGENT_SECRET) {
  console.error("Missing WECHAT_AGENT_SECRET");
  process.exit(1);
}

server.listen(PORT, () => {
  console.log(`cloud queue listening on :${PORT}`);
  console.log("wechat endpoint: /wechat");
});
