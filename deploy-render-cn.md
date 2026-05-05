# Render.com 免费部署教程

本教程指导你将 `cloud-wechat-queue.js` 部署到 [Render.com](https://render.com)（免费方案）。

## 1. 注册 Render 账号

打开 [render.com](https://render.com)，点击 **Get Started**。

推荐用 **GitHub 账号**直接登录，后续部署会更方便。

## 2. 准备代码仓库

### 方式一：通过 GitHub（推荐）

1. 在 GitHub 创建一个**私有仓库**
2. 将本项目上传到该仓库：

```powershell
cd C:\Users\QianAy\Documents\Codex\2026-05-01\codex-deepseek-v4

git init
git add .
git commit -m "初始化微信桥接项目"
git remote add origin https://github.com/你的用户名/你的仓库名.git
git push -u origin main
```

3. 在 Render 中选择 **Web Service** → 连接你的 GitHub 仓库

### 方式二：手动上传

1. 在 Render 中选择 **Web Service** → **Public Git repository**
2. 或者使用 Render 的 **Deploy from existing image** 功能

## 3. 创建 Web Service

在 Render 控制台：

1. 点击 **New +** → **Web Service**
2. 选择你的仓库
3. 填写以下配置：

| 配置项 | 值 |
|--------|-----|
| **Name** | 随便取，如 `wechat-bridge` |
| **Runtime** | `Node` |
| **Build Command** | `npm install` |
| **Start Command** | `node cloud-wechat-queue.js` |
| **Instance Type** | **Free** |

## 4. 设置环境变量

在 **Environment** 部分添加：

| 变量名 | 值 | 说明 |
|--------|-----|------|
| `WECHAT_TOKEN` | `你自定的随机字符串` | 微信签名验证用，随便设置 |
| `WECHAT_AGENT_SECRET` | `一段很长的随机字符串` | 代理密钥，建议32位以上随机字符 |
| `WECHAT_AUTO_BIND_OWNER` | `1` | 自动绑定第一个发消息的人 |
| `WECHAT_OWNER_OPENID` | 留空 | 留空则会自动绑定 |
| `PORT` | `8788` | 端口号（可选，默认 8788） |

> **生成随机密钥**：可以在 PowerShell 中执行以下命令生成：
> ```powershell
> -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
> ```

## 5. 部署

点击 **Create Web Service**，等待部署完成（通常 2-3 分钟）。

部署成功后，你会看到状态变为 **Live**，并得到一个域名如：
```
https://wechat-bridge.onrender.com
```

## 6. 验证部署

### 测试健康检查

浏览器或 PowerShell 中访问：
```
https://你的域名.onrender.com/health
```

应该返回类似：
```json
{
  "ok": true,
  "uptime": 123.45,
  "queued": 0,
  "results": 0,
  "ownerBound": false,
  "memoryMB": 25,
  "persistence": "none"
}
```

### 测试微信接入点

```powershell
# 模拟微信验证请求（将 token 换成你设置的 WECHAT_TOKEN）
$token = "你设置的token"
$timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds().ToString()
$nonce = "random123"
# 计算签名需要 sha1，这里只是验证端口通不通
curl "https://你的域名.onrender.com/wechat?signature=test&timestamp=$timestamp&nonce=$nonce&echostr=hello"
```

返回 `bad signature` 是正常的（因为签名不对），说明服务在正常运行。

## 7. 配置微信测试号

现在回到 [微信测试号管理页面](https://mp.weixin.qq.com/debug/cgi-bin/sandbox?t=sandbox/login)：

1. **URL**：填写 `https://你的域名.onrender.com/wechat`
2. **Token**：填写你设置的 `WECHAT_TOKEN`

点击**提交**，微信会验证你的服务，成功后就配置完成了。

> **注意**：如果验证失败，请检查：
> - URL 是否以 `https://` 开头（不是 `http://`）
> - Token 是否和环境变量中的 `WECHAT_TOKEN` 完全一致（区分大小写）
> - 尝试手动访问 `https://你的域名.onrender.com/health` 确认服务在运行

## 8. 免费方案的注意事项

Render 免费方案的**限制**：

| 限制项 | 说明 |
|--------|------|
| **休眠机制** | 15 分钟无请求后服务会休眠 |
| **唤醒时间** | 收到请求后需要 30-60 秒唤醒 |
| **每月时长** | 750 小时（足够日常使用） |
| **内存** | 512 MB |
| **持久化** | 会定期重置（队列数据可能丢失） |

**应对休眠**：本地代理每 3 秒轮询一次，所以只要代理在运行，服务就不会休眠。

**应对数据丢失**：v2.0 的 JSON 文件持久化可以帮助恢复，但不能完全避免丢失。如果需要更可靠的方案，可以：
- 使用 [Supabase](https://supabase.com) 免费数据库替代 JSON 文件
- 升级到 Render 付费方案（约 $7/月）

## 常见部署问题

### Q: 部署失败，日志显示 "Missing WECHAT_TOKEN"？

你需要在 Render 的环境变量中设置 `WECHAT_TOKEN`。设置后需要**重新部署**。

### Q: 微信验证一直失败？

依次检查：
1. `https://你的域名.onrender.com/health` 能否正常访问
2. URL 填的是 `https://` 开头
3. Token 值完全一致（包括大小写）
4. 在 Render 的 Logs 中查看是否有请求到达

### Q: 我可以部署到其他平台吗？

完全可以。`cloud-wechat-queue.js` 是一个标准的 Node.js HTTP 服务，可以部署到任何支持 Node.js 的平台：
- **Fly.io**（免费 3 台 VM）
- **Railway**（已取消免费，但价格低）
- **Vercel**（需要改造为 Serverless Functions）
- **自己的 VPS**（最稳定，国内阿里云/腾讯云轻量服务器几十元/月）
