# 微信测试公众号 → Claude Code AI 桥接系统

通过微信测试公众号发送指令，让本地电脑上的 **Claude AI（或 DeepSeek V4）** 自动执行代码修改、智能问答、代码审查等任务。

## 工作原理

```
你在微信发指令 → 云队列(Render免费托管) → 你的电脑轮询取任务 → Claude AI执行 → 结果返回微信
```

**你的电脑不需要公网 IP**，只发出 HTTPS 请求，安全可靠。

## 功能一览

| 命令 | 功能 | 示例 |
|------|------|------|
| `ask <问题>` / `问答 <问题>` | AI 问答 | `ask Python如何读取JSON` |
| `dev <项目> <需求>` / `需求 <项目> <需求>` | AI 修改代码 | `需求 myapp 修复登录校验bug` |
| `review <项目>` / `审查 <项目>` | AI 代码审查 | `review myapp` |
| `git status <项目>` / `git状态 <项目>` | 查看代码状态 | `git status bridge` |
| `git diff <项目>` / `git差异 <项目>` | 查看代码差异 | `git diff bridge` |
| `git commit <项目> <说明>` / `git提交 <项目> <说明>` | 提交代码 | `git commit bridge 修复bug` |
| `confirm <操作ID>` | 确认提交 | `confirm commit-20260504-223000` |
| `status` / `状态` | 电脑运行状态 | `状态` |
| `log` / `日志` | 最近执行日志 | `日志` |
| `result` / `结果` | 查看最近执行结果 | `结果` |
| `time` / `时间` | 当前时间 | `时间` |
| `ls` / `目录` | 列出文件 | `目录` |
| `help` / `帮助` | 查看帮助 | `帮助` |

## 前置条件

开始之前，你需要准备以下内容：

### 1. 微信测试公众号（免费）

打开 [微信公众平台测试号](https://mp.weixin.qq.com/debug/cgi-bin/sandbox?t=sandbox/login)，用微信扫码登录。

你会得到：
- **appID** 和 **appsecret**（暂时不需要）
- 一个**测试公众号二维码**，扫码关注后你就是该号的粉丝

### 2. 云服务部署（免费）

你需要一台能运行 Node.js 的云服务器来部署消息队列。推荐以下免费方案：

**Render.com**（推荐，最稳定）
- 免费额度：每月 750 小时
- 支持 Node.js
- 有公网 HTTPS 地址
- 详见：[Render 部署教程](./deploy-render-cn.md)

其他可选方案：
- Fly.io（免费 3 台共享 VM）
- Cloudflare Workers（每天 10 万次请求）

### 3. 本地电脑环境

- **Windows 10/11**（已确认可用）
- **Node.js** v18 或更高（用于本地测试）
- **Claude Code CLI**（已安装 `claude` 或 `codex` 命令）
- **PowerShell 5.1 或更高**
- **Git**（用于代码管理）

## 快速开始（三步走）

### 第一步：部署云队列

参考 [Render 部署教程](./deploy-render-cn.md) 部署 `cloud-wechat-queue.js`。

部署完成后，你会得到一个类似 `https://你的应用.onrender.com` 的地址。

记下你在部署时设置的：
- **WECHAT_TOKEN**（微信签名验证用，随便设一个如 `mywechattoken2024`）
- **WECHAT_AGENT_SECRET**（代理密钥，设一个长的随机字符串）

### 第二步：配置微信测试号

1. 打开 [微信测试号管理页面](https://mp.weixin.qq.com/debug/cgi-bin/sandbox?t=sandbox/login)
2. 在"接口配置信息"中填写：
   - **URL**：`https://你的应用.onrender.com/wechat`
   - **Token**：你设置的 `WECHAT_TOKEN`
3. 点击"提交"，微信会验证你的云服务

### 第三步：启动本地代理

打开 **PowerShell**（以管理员身份运行），执行：

```powershell
cd C:\Users\QianAy\Documents\Codex\2026-05-01\codex-deepseek-v4

# 设置环境变量
$env:WECHAT_QUEUE_URL = "https://你的应用.onrender.com"
$env:WECHAT_AGENT_SECRET = "你设置的代理密钥"

# 启动代理
powershell -ExecutionPolicy Bypass -File .\local-agent.ps1
```

看到 `微信桥接代理启动` 的提示就是成功了。

### 第四步：在微信发指令测试

打开微信，找到你的测试公众号，发送：

```
帮助
```

你会收到命令列表。然后试试：

```
时间
```

如果返回当前时间，说明整个链路通了！

再试试 AI 功能：

```
问答 Python中如何读取CSV文件
```

AI 会返回详细的解答。

## 添加更多项目

编辑 `projects.json`，添加你要从微信操控的项目：

```json
{
  "defaultProject": "bridge",
  "projects": {
    "bridge": {
      "path": "C:\\Users\\QianAy\\Documents\\Codex\\2026-05-01\\codex-deepseek-v4"
    },
    "myapp": {
      "path": "C:\\Users\\QianAy\\Documents\\Projects\\myapp"
    },
    "mybackend": {
      "path": "D:\\Code\\my-backend-project"
    }
  }
}
```

然后就可以在微信中这样用：

```
需求 myapp 把首页按钮颜色改成蓝色
审查 mybackend
git状态 myapp
```

## 添加自定义命令

编辑 `commands.json`，可以添加简单的快捷命令：

```json
{
  "commands": {
    "build": {
      "command": "npm run build",
      "workingDirectory": "C:\\Users\\QianAy\\Documents\\Projects\\myapp",
      "timeoutSeconds": 120
    }
  }
}
```

**安全提示**：不要添加可能造成破坏的命令（如 `rm`、`del`、`format` 等）。命令会以当前用户的权限运行。

## 目录结构

```
codex-deepseek-v4/
├── cloud-wechat-queue.js        云队列服务（部署到 Render）
├── local-agent.ps1              本地轮询代理（在你的电脑运行）
├── wechat-command-runner.ps1    命令执行器（核心逻辑）
├── commands.json                白名单命令配置
├── projects.json                项目别名配置
├── package.json                 包信息
├── .env.example                 环境变量示例
├── .codex-wechat/
│   ├── inbox/                   开发需求存档
│   └── pending/                 待确认操作
├── README.md                    本说明文档
└── deploy-render-cn.md          Render 部署教程
```

## 安全说明

1. **谁可以发命令？** 只有绑定的微信用户（第一个关注测试号的人自动绑定，或手动设置 `WECHAT_OWNER_OPENID`）
2. **AI 可以做什么？** 在问答模式下，AI 不能修改文件；在开发模式下，AI 只能操作指定项目目录
3. **命令限制**：只能执行 `commands.json` 中白名单的命令
4. **速率限制**：每分钟最多 10 条消息
5. **超时控制**：普通命令 60 秒超时，AI 任务 5 分钟超时

## 常见问题

### Q: 云服务部署后微信验证失败？

检查：
- URL 是否以 `https://` 开头
- Token 是否和云服务设置的 `WECHAT_TOKEN` 完全一致
- 访问 `https://你的域名/health` 是否能正常返回

### Q: 本地代理启动后没有反应？

检查：
- `WECHAT_QUEUE_URL` 和 `WECHAT_AGENT_SECRET` 是否正确
- 网络是否能访问云服务地址
- 防火墙是否阻止了 PowerShell 的网络访问

### Q: AI 任务执行失败？

- 检查 `claude` 命令是否可用：在 PowerShell 中执行 `claude --version`
- 确认 Claude CLI 已登录：执行 `claude auth` 查看状态
- 查看日志：发送 `日志` 到公众号

### Q: 可以多个人使用吗？

当前版本只支持单人使用（绑定第一个关注者）。如果需要多人使用，需要改造 `cloud-wechat-queue.js` 添加用户管理。

### Q: 云服务重启后数据会丢失吗？

不会。v2.0 版本使用 JSON 文件持久化队列和结果，重启后会自动恢复。

### Q: 可以不用云服务吗？

不能完全不用，因为微信需要一个公网可访问的 URL 来接收消息。但 Render.com 的免费额度对于个人使用完全足够。

## 技术支持

如果遇到问题，可以：
1. 发送 `日志` 到公众号查看最近的运行日志
2. 查看本地 `agent-log.txt` 文件了解详细错误
3. 运行 `node cloud-wechat-queue.js` 直接查看云队列日志
