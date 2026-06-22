# The Unspoken Gift — 项目须知

单文件双语（EN / 中文）精品礼盒电商网站（新加坡）。原生 HTML/CSS/JS，无构建步骤。

## Live site / 部署（最重要）

- ✅ **有效链接：https://fluffyland.github.io/the-unspoken-gift/**
- ❌ 不要再引用任何 `https://leejianwei8313.github.io/*` 旧链接（用户名已由
  `leejianwei8313` 改名为 `fluffyland`，旧 `*.github.io` 链接全部 404，且不会跳转）。
  仓库也已从 `coding` 改名为 `the-unspoken-gift`；git remote 仍叫 `coding`，
  靠 GitHub 自动跳转，`push` / `ls-remote` 照常生效，无需改 remote 或重新关联。
- 部署方式：GitHub Pages，**Deploy from a branch = `claude/gift-box-sales-redesign-ar81tt`**，
  根目录 `index.html`。推送到该分支后，「pages build and deployment」自动部署，1–2 分钟生效。

## 工作流约束（每次改动都要遵守）

1. **每次改动新建递增编号文件** `theunspokengift_NN.html`（从最新一版复制），
   **绝不覆盖或替换旧文件**。当前最新为 `theunspokengift_22.html`。
2. 改完 `cp theunspokengift_NN.html index.html`（Pages 服务的就是 `index.html`）。
3. 提交并 `git push -u origin claude/gift-box-sales-redesign-ar81tt`。
4. **不开 PR**，除非用户明确要求。
5. 交付时把新建的 `theunspokengift_NN.html` 发给用户，并附上有效链接。
