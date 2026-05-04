# WeChat Test Account Queue Bridge

This version avoids exposing your computer to the public internet.

Architecture:

```text
WeChat -> cloud webhook -> in-memory task queue
local PC agent -> polls cloud -> runs whitelisted command -> posts result
WeChat -> send "result" -> read latest output
```

Your computer only makes outbound HTTPS requests.

## Files

```text
cloud-wechat-queue.js       Cloud webhook and task queue
local-agent.ps1             Local polling agent
wechat-command-runner.ps1   Whitelisted command executor
commands.json               Allowed local commands
```

## 1. Deploy The Cloud Webhook

Deploy `cloud-wechat-queue.js` to a Node.js host, such as a small VPS, Render, Railway, Fly.io, or any serverless/container platform that supports Node's built-in `http` module.

Set environment variables on the cloud host:

```text
WECHAT_TOKEN=your-random-wechat-token
WECHAT_AGENT_SECRET=your-long-random-agent-secret
WECHAT_OWNER_OPENID=optional-your-openid
WECHAT_AUTO_BIND_OWNER=1
PORT=8788
```

Security notes:

```text
WECHAT_TOKEN is for WeChat signature verification.
WECHAT_AGENT_SECRET is only for the local PC agent.
WECHAT_OWNER_OPENID restricts who can enqueue commands.
WECHAT_AUTO_BIND_OWNER=1 binds the first sender if WECHAT_OWNER_OPENID is empty.
```

After deployment, verify:

```text
https://your-cloud-host/health
```

## 2. Configure WeChat Test Account

Open:

```text
https://mp.weixin.qq.com/debug/cgi-bin/sandbox?t=sandbox/login
```

Set:

```text
URL:   https://your-cloud-host/wechat
Token: the same value as WECHAT_TOKEN
```

WeChat will call the cloud webhook, not your PC.

## 3. Start The Local Agent

On this computer:

```powershell
cd C:\Users\QianAy\Documents\Codex\2026-05-01\codex-deepseek-v4
$env:WECHAT_QUEUE_URL = "https://your-cloud-host"
$env:WECHAT_AGENT_SECRET = "same-long-random-agent-secret"
powershell -ExecutionPolicy Bypass -File .\local-agent.ps1
```

## 4. Use In WeChat

Send:

```text
help
time
ls
结果
```

Chinese aliases are also configured:

```text
帮助
时间
目录
结果
```

The first command message returns a queued task id. A few seconds later, send `结果` to read the latest output.

## 5. Add Safe Commands

Edit `commands.json`.

Example:

```json
{
  "commands": {
    "dev": {
      "command": "npm run dev",
      "workingDirectory": "C:\\path\\to\\project",
      "timeoutSeconds": 30
    }
  }
}
```

Do not add unrestricted shell execution. Keep command names explicit and fixed.

## Important Limitations

This MVP uses an in-memory queue on the cloud host. If the cloud process restarts, queued tasks and results are lost.

For long-term use, replace the arrays in `cloud-wechat-queue.js` with Redis, SQLite, Supabase, Cloudflare KV/D1, or another persistent store.
