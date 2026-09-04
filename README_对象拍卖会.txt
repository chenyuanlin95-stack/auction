# 对象拍卖会 · 添加方法

不会改动现有「人生拍卖会」。

1. 把 `love-host.html`、`love-play.html`、`love-lots.js`、`love-shared.js` 上传到现有 GitHub 仓库根目录。
2. `styles.css` 和现有 `config.js` 继续共用，不需要替换。
3. 打开 Supabase → SQL Editor，新建 Query，把 `supabase_对象拍卖会.sql` 全部粘贴并 Run 一次。
4. 主持人打开 `https://chenyuanlin95-stack.github.io/auction/love-host.html`。
5. 创建房间后让玩家扫页面二维码即可。

规则：每人 25,000,000 元；所有对象 100 万起拍；每次加价 100 万。玩家竞价输入框单位是「万」（输入 500 = 500 万），资产余额按「元」显示。
