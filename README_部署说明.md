# 人生拍卖会 · 多手机实时版

这版已经拆成：
- `host.html`：主持人电脑端
- `play.html`：玩家手机端
- `supabase.sql`：数据库 + 实时同步 + 原子竞价逻辑
- `config.js`：只需要填 Supabase 的 Project URL 和 anon/public key
- `lots.js`：58 件完整拍品
- `styles.css` / `shared.js`：界面和公共逻辑

## 第一次配置（约 10 分钟）

1. 打开 Supabase，新建一个免费 Project。
2. 进入 **SQL Editor**，新建 Query，把 `supabase.sql` 全部粘贴进去并 Run。
3. 在 Supabase 项目的 **Settings / API**（不同版本界面可能写作 Project Settings / Data API）里找到：
   - Project URL
   - anon / public key
4. 打开 `config.js`，把两处 `PASTE_...` 替换为你自己的值。
   **不要填写 service_role key，只填 anon/public key。**
5. 把整个文件夹部署到任意静态网页托管平台（Vercel、Netlify、GitHub Pages 都可以）。
   不能直接把本地 `file://` 路径发给朋友，因为他们的手机访问不到你电脑里的本地文件。
6. 打开部署后的 `host.html`，创建房间。页面会自动生成房间码、玩家加入链接和二维码。
7. 朋友扫码，输入昵称，开始竞拍。

## 测试方法

部署前也可以先在电脑本地用简单 HTTP Server 测界面：
- Windows / macOS 已安装 Python 时，在本文件夹打开终端：
  `python -m http.server 8000`
- 然后浏览器访问：
  `http://localhost:8000/host.html`

但**不同手机要参与，仍需要一个所有手机都能访问的网址**；最省事的是部署到 Vercel / Netlify / GitHub Pages。

## 当前规则

- 每位玩家初始资产：¥150,000,000
- LOT 1–20：起拍 ¥1,000,000，最低加价 ¥500,000
- LOT 21–40：起拍 ¥2,000,000，最低加价 ¥1,000,000
- LOT 41–50：起拍 ¥5,000,000，最低加价 ¥1,000,000
- LOT 51–58：起拍 ¥10,000,000，最低加价 ¥2,000,000
- 玩家可以跳价，只要达到“当前价格 + 最低加价”
- 成交时才实际扣款
- 同一时刻多人同时出价时，数据库会锁定房间行，按服务器实际收到的顺序处理，避免两个“最高价”同时成立

## 这版的权限

玩家端只提供：
- 当前拍品
- 当前最高价 / 最高出价者
- 自己的剩余资产
- 出价
- 自己的藏品

主持人端提供：
- 创建房间 / 二维码
- 查看所有玩家余额
- 选择 58 件拍品
- 开拍
- 落槌
- 流拍
- 下一件
- 查看成交记录

## 原型安全说明

这是给熟人聚会使用的原型，为了让搭建足够简单，数据库表暂时没有启用严格 RLS。
不要把这个 Supabase 项目拿去做公开商业站点，也不要在里面存任何隐私信息。
如果最终要长期公开使用，再把权限改成严格 RLS / Edge Function 即可。
