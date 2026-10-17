# BongoCat-X Arch Linux 软件源

用 GitHub Actions + Cloudflare Pages 搭起来的**全自动 Arch Linux 私有软件源**：上游
[BongoCat-X](https://github.com/TianMengLucky/BongoCat-X) 一发新版本，这里就会自动取回它
编译好的 Linux 归档、用 GPG 签名、重建软件源索引，并推送到 Cloudflare Pages。

没有常驻服务器，不需要 R2，也不需要自己开机器：所有产物都是静态文件，靠 Pages 的全球 CDN
分发。

```
    上游 GitHub Release
            │  每 6 小时轮询 / 手动触发
            ▼
   ┌──────────────────┐        ┌───────────────────────────────┐
   │ detect 作业       │        │ GitHub Release（滚动存储）      │
   │ 解析最新正式 tag， │        │ arch-repo-store               │
   │ 决定是否重建/重发布│        │  *.pkg.tar.zst(+.sig)          │
   └────────┬─────────┘        └───────────────┬───────────────┘
            │ 有新版本                        │ 取回全部包
            ▼                                  ▼
   ┌──────────────────────────────┐   ┌───────────────────────────┐
   │ build 作业（archlinux 容器）   │   │ publish 作业（archlinux）  │
   │ 非 root 用户 makepkg          │   │ repo-add --sign 重建索引   │
   │ 复用上游 release 归档          │──▶│ 用 pacman 自己验签校验     │
   │ Cubism SDK 官方下载并解包      │   │ wrangler pages deploy     │
   │ 结构校验 + ldd 依赖校验        │   │ 提交 PKGBUILD 版本号       │
   └──────────────────────────────┘   └─────────────┬─────────────┘
                                                    ▼
                                    Cloudflare Pages（全球 CDN）
                                    https://bongocat.zakofox.cn/x86_64
                                                    │
                                                    ▼
                                    开发机：pacman -Syu bongocat-x-bin
```

## 软件源里有什么

| 包 | 内容 | 从哪来 |
| --- | --- | --- |
| `bongocat-x-bin` | BongoCat-X 本体 + Live2D 渲染插件 | 直接复用上游 release 的官方 Linux 归档 |
| `live2d-sdk-nonfree` | 专有的 `libLive2DCubismCore.so` | 从 Live2D 官网下载 Cubism SDK for Native 后解包 |
| `bongocat-x-git` | 同上，但本机编译上游 `dev` 分支 | **只在本仓库源码里**，不在软件源发布 |

`bongocat-x-git` 需要 Rust 工具链、glslang 和整个 Cubism SDK 在**用户机器上**编译完成。
让 `pacman -Syu` 去触发这件事不合适，所以它不进 `PUBLISHED_PACKAGES`，CI 也不构建它 ——
要装它请自己 `makepkg`（见下）。

## Live2D 核心库为什么要单独一个包

上游 2.2.x 起改成 **runtime-Core** 设计：`libLive2DCubismCore.so` 不链接进可执行文件，程序在
运行时用 `dlopen` 从程序目录旁的 `live2d/` 加载它。这是必须的，因为 Cubism Core 是 Live2D 的
专有软件，其许可不允许再分发。

所以装 `bongocat-x-bin` 之后 Live2D 渲染是缺的，装上 `live2d-sdk-nonfree` 才补齐：

```bash
sudo pacman -S bongocat-x-bin live2d-sdk-nonfree
```

也可以不装这个包，改用程序自带的导入功能：设置 → 插件 → 导入 Live2D Core。

## 客户端使用

一键配置（会先校验签名密钥指纹，再写入 `/etc/pacman.conf`）：

```bash
curl -fsSL https://bongocat.zakofox.cn/setup.sh | sudo bash
sudo pacman -S bongocat-x-bin live2d-sdk-nonfree
```

手动配置等价于在 `/etc/pacman.conf` 末尾追加：

```ini
[bongocat-x]
SigLevel = Required DatabaseOptional
Server = https://bongocat.zakofox.cn/$arch
```

然后导入并本地签名仓库公钥（指纹见站点首页，务必核对）：

```bash
curl -fsSLO https://bongocat.zakofox.cn/bongocat-x-repo.asc
sudo pacman-key --add bongocat-x-repo.asc
sudo pacman-key --lsign-key <KEY_ID>
sudo pacman -Syu
```

`SigLevel = Required` 意味着**每个包都必须有有效签名**才会被安装，软件源索引也带签名；
`DatabaseOptional` 允许索引签名缺失时降级，但这里始终提供签名。

> `bongocat-x-bin` 直接复用上游在 Ubuntu 上构建的归档，可能依赖较新的 glibc。安装前先
> `pacman -Syu` 把系统更新到最新，这是 Arch 的常规做法。

## 仓库结构

| 路径 | 作用 |
| --- | --- |
| `packages/*/PKGBUILD` | 每个包一个目录；构建 + 结构校验 + 依赖自检 |
| `packages/*/verify-files` | 该包必须包含的路径清单，`build-package.sh` 据此校验产物 |
| `repo.conf` | 仓库级设置：仓库名、CI 要发布的包、上游仓库 |
| `repo-site/` | Pages 站点模板：首页、缓存策略 `_headers`、客户端脚本 `setup.sh` |
| `scripts/detect-upstream.sh` | 解析上游最新 release，决定重建/重发布 |
| `scripts/build-package.sh` | 构建 + 签名 + 产物校验（CI 与本地通用），参数为包名 |
| `scripts/assemble-repo.sh` | 从滚动存储取包、重建并签名索引、生成站点目录 |
| `scripts/verify-repo.sh` | 以客户端视角验证：pacman 同步 + 下载 + 验签 |
| `scripts/store-api.sh` | 滚动 Release 存储的 GitHub API 封装（上传/下载/清理） |
| `scripts/gpg.sh` | 无人值守签名所需的 GnuPG 配置与导入 |
| `scripts/set-pkgver.sh` | 更新一个或全部包的版本号并刷新各自的 `.SRCINFO` |
| `scripts/publish-store.sh` | 上传产物到滚动存储并按保留数清理 |
| `scripts/common.sh` | 公共函数（日志、版本比较、包目录枚举等） |
| `.github/workflows/build-repo.yml` | 全流程编排：detect → build → publish |

## 维护者配置

### 1. 生成仓库签名密钥

在本地一次性生成（**不要**设置口令也行，CI 里用 `GPG_PASSPHRASE` secret 支持带口令的密钥）：

```bash
# 建议用 RSA 4096 或 ed25519，这里以 RSA 为例
gpg --batch --quick-generate-key "BongoCat Arch Repo <you@example.com>" rsa4096 sign never
KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')
gpg --armor --export-secret-keys "$KEY_ID" > private.key     # → 存进 GitHub Secret
gpg --armor --export "$KEY_ID" > public.asc                  # 公钥，会上传到站点
gpg --fingerprint "$KEY_ID"                                  # 记下指纹，发布后核对
```

`private.key` 只在添加 Secret 时用一次，用完立刻删除，不要提交到仓库。

### 2. 准备 Cloudflare Pages

1. 在 Cloudflare 控制台建一个 API Token：**My Profile → API Tokens → Create Token**，
   权限选 `Account → Cloudflare Pages → Edit`。
2. 记下 **Account ID**（控制台右侧栏或 URL 里）。
3. Pages 项目不用手动建，工作流首次发布会自动 `wrangler pages project create`
   （默认项目名 `bongocat-arch`，因此 `https://bongocat-arch.pages.dev` 始终可用作备用地址）。
4. 自定义域名 `bongocat.zakofox.cn` 需要在 Pages 项目里挂上去：
   项目 → **Custom domains** → **Set up a domain** → 填 `bongocat.zakofox.cn`。
   因为 `zakofox.cn` 就在同一个 Cloudflare 账户下，CNAME 记录会自动创建，之后
   `https://bongocat.zakofox.cn` 与 `*.pages.dev` 提供完全相同的内容。

   两点注意：
   - 不要给这个域名加 **Cloudflare Access**，否则工作流里那条“站点是否落后于存储”的自愈检查
     读不到索引文件；
   - 不要给这个域名加 "Cache Everything" 之类的 Cache Rule —— 索引文件的缓存策略由仓库里的
     `_headers` 决定（包体 1 年不可变、索引 300 秒），强行全缓存会让 `pacman -Syu` 看到旧索引。

### 3. 配置 Secrets 与 Variables

仓库 **Settings → Secrets and variables → Actions**：

| 类型 | 名称 | 说明 |
| --- | --- | --- |
| Secret | `GPG_PRIVATE_KEY` | 上一步的 `private.key` 全文（含 BEGIN/END 行） |
| Secret | `GPG_PASSPHRASE` | 可选，密钥口令；不设则按无口令密钥处理 |
| Secret | `CLOUDFLARE_API_TOKEN` | Pages 部署令牌 |
| Secret | `CLOUDFLARE_ACCOUNT_ID` | Cloudflare 账户 ID |
| Variable | `PAGES_PROJECT` | 可选，Pages 项目名，默认 `bongocat-arch` |
| Variable | `SITE_URL` | 可选，站点地址，默认 `https://bongocat.zakofox.cn` |
| Variable | `UPSTREAM_REPO` | 可选，上游仓库，默认取自 `repo.conf` |
| Variable | `KEEP_VERSIONS` | 可选，保留最近几个版本，默认 `3` |
| Variable | `STORE_TAG` | 可选，滚动存储用的 tag，默认 `arch-repo-store` |

`SITE_URL` 会写进客户端的 `pacman.conf`、`setup.sh` 和站点首页，所以要填客户端最终使用的地址。

### 4. 首次运行

推送到默认分支后，在 **Actions → Arch repository → Run workflow** 手动触发一次
（首次建议勾上 `force`），随后它会按每 6 小时的计划自动检查上游。

## 流水线做了什么

### 上游侦测（`detect`）

- 读取上游 `/releases/latest`，过滤掉 prerelease tag（nightly）只认正式发布；
- 解析 tag 与对应 commit，与 `packages/bongocat-x-bin/PKGBUILD` 里的 `pkgver` 比较：相同则
  **直接跳过**，不构建、不部署，避免无谓消耗；
- 顺带对比「滚动存储里的包名集合」与「线上站点索引里的包名集合」，不一致就重发布 —— 上一次
  部署中断也不会让站点长期落后，下一次计划任务会自动修复；
- 手动 `workflow_dispatch` 可指定 `tag`（取指定版本）或 `force`（同版本重打包，自动
  `pkgrel+1`，这样文件名与索引都指向新构建）。

### 构建与签名（`build`）

- 在 `archlinux:base-devel` 容器里，用非 root 的 `builder` 用户执行 `makepkg`
  （`makepkg` 明确拒绝 root 运行），依赖由工作流预先 `pacman -S` 装好，因此不需要 sudo；
- 遍历 `repo.conf` 的 `PUBLISHED_PACKAGES` 逐个调用 `scripts/build-package.sh <包名>`，依赖
  也是从各 PKGBUILD 里收集后一起安装的；
- **`bongocat-x-bin` 不编译**：它下载上游 release 归档，比对上游自己发布的 `.sha256` sidecar 与
  固定的 pin 值，然后解包重排。`sha256sums` 钉的是 GitHub 的 asset digest，因为 GitHub 会
  就地重新打包 release 归档，URL 稳定而内容哈希会变；
- **`live2d-sdk-nonfree` 从 Live2D 官网下载** Cubism SDK for Native 5-r.5（SHA-256 固定），
  解包取出 `Core/dll/linux/x86_64/libLive2DCubismCore.so` 装到程序扫描的 `live2d/` 目录。
  这是专有软件，许可禁止再分发，因此单独成包而不是并进 `bongocat-x-bin`；
- 构建后立即自检：可执行文件存在、**6 个渲染插件齐全**、`licenses/Inox2D-LICENSE` 与必需
  资源文件在位、`ldd` 无缺失库。`-git` 包还会额外断言**每个 `NEEDED` 的 so 都能在 `depends`
  里找到归属包** —— 上游一旦引入新依赖，这里会直接失败，而不是发布一个装不上的包；
- 每个包构建完自检 **Core 没泄漏进包内**，这是 `live2d-sdk-nonfree` 存在的全部意义；
- 签名采用 git 之外的独立 `gpg --detach-sign`，产物与 `.sig` 一起上传到滚动 Release 存储；
- `namcap` 结果作为参考写进 job summary（不阻塞发布）。

### 索引与发布（`publish`）

- 从滚动 Release 取回全部历史包（按 `KEEP_VERSIONS` 清理更早的），一次性 `repo-add --sign`
  重建 `bongocat-x.db.tar.gz` 与 `bongocat-x.files.tar.gz` 并签名；
- `repo-add` 生成的 `.db`/`.db.sig`/`.files`/`.files.sig` 是**符号链接**，而 Pages 是对象
  存储、不提供符号链接，脚本会把它们替换成内容完全相同的真实文件（签名校验的是字节，
  因此依然有效），并断言部署目录里没有残留符号链接；
- 断言索引里出现的每个文件名和签名都真实存在于部署目录，避免发布出「索引指向 404」的坏源；
- 用 `pacman` 自己跑一遍客户端流程：临时 `GPGDir`/`DBPath`/`CacheDir` + `file://` 源，
  `pacman -Sy` 同步索引、`pacman -Si` 读元数据、`pacman -Sddw` 下载并按 `SigLevel = Required`
  验签 —— 任何签名或索引问题都会在这里拦住；
- `wrangler pages deploy` 推送整个目录（每次部署都是全量快照）；
- 部署成功后才把新版本号提交回 `packages/*/PKGBUILD` 与 `.SRCINFO`；失败则保留旧版本号，
  让下一次计划任务重新构建并自愈。

### 为什么用 GitHub Release 做包存储

Cloudflare Pages 每次部署都是一份完整快照，没有「增量保留旧文件」的机制，所以必须有个地方
长久保存历史包。Release 资产天然适合：不占仓库体积、可审计、带 token 就能读写，还顺带成为
一个下载备份入口。清理旧包时同步删除 Release 资产和部署目录里的文件，两边始终一致。

## 本地构建与验证

本机是 Arch 时，可以直接跑完整流程：

```bash
# 从源码编译（会下载 Cubism SDK 与 GLEW，并校验 SHA-256）
cd packages/bongocat-x-git && makepkg -f --noconfirm

# 或者用 CI 同款脚本（会顺带签名，需要一个可用的签名密钥）
GPG_PRIVATE_KEY="$(cat private.key)" scripts/build-package.sh bongocat-x-bin --out dist

# 组装部署目录（需要能访问滚动存储，即 GH_TOKEN + STORE_REPO）
GH_TOKEN=... STORE_REPO=owner/repo scripts/assemble-repo.sh --keep 3 --site-url https://bongocat.zakofox.cn

# 以客户端视角验证产物：同步索引 + 下载 + 验签（需要 root 才能真正跑 pacman）
sudo scripts/verify-repo.sh --dir public
```

只看上游侦测结果、不碰任何远端状态：

```bash
scripts/detect-upstream.sh --repo TianMengLucky/BongoCat-X
```

## 设计与限制

- **为什么不编译 `bongocat-x`**：上游 2.2.x 把 Cubism Core 改成运行时加载，光有 SDK 编出来
  的插件仍然缺 Core 库。与其为每个用户编译一遍，仓库直接发布上游自己构建好的归档更省事，
  也更贴近「用户装到的就是官方验证过的东西」。

- **为什么不发布 `bongocat-x-git`**：它需要 Rust 工具链、glslang 与整个 Cubism SDK 在用户
  机器上跑完编译。让 `pacman -Syu` 触发这个不现实，`makepkg` 才是它该待的地方。

- **Cubism SDK 许可**：Live2D Cubism SDK for Native 与 `libLive2DCubismCore.so` 是专有软件，
  遵循 [Live2D Proprietary Software License Agreement](https://www.live2d.com/en/sdk/license/)，
  构建时从官方地址获取。它们不并进 `bongocat-x-bin`，而是作为 `live2d-sdk-nonfree` 单独分发。
  本仓库自身的编排脚本以 MIT 授权（见 `LICENSE`）。

- **上游关系**：本仓库只是第三方自动化打包，与 BongoCat 作者无关；软件本身是 AGPL-3.0-only，
  模型资源为 MIT（见 `/usr/share/licenses/bongocat-x-*/`）。

- **`bongocat-x-bin` 的哈希 pin**：GitHub 会就地重新打包 release 归档，所以 `sha256sums` 钉的是
  GitHub 自己公布的 asset digest，而 `package()` 会再拿上游的 `.sha256` sidecar 交叉验证一次。
  上游重新上传同名资产时会被这里拦住，而不是悄悄装进一个来路不明的文件。

- **25 MiB 单文件上限**：构建脚本硬性检查产物大小，超限直接失败并说明原因（Pages 的每文件
  限制）。上游 `BongoCat-X-2.2.0-linux-x64.tar.gz` 是 16.8 MiB，解包安装后更小，离上限还很远。

- **`nightly` 被故意忽略**：上游的 nightly 是 prerelease，检测脚本用 `grep -E '^v[0-9]'` 过滤，
  只跟正式发布。

## 常见问题

**站点起来了，但 `pacman -Sy` 报签名错误。**
先确认导入的是站点上的 `bongocat-x-repo.asc` 并且做过 `pacman-key --lsign-key`。用
`sudo pacman-key --finger <KEY_ID>` 核对指纹是否与站点首页一致。

**索引是旧的。**
`bongocat-x.db` 与 `bongocat-x.files` 的缓存是 300 秒，稍等或 `sudo pacman -Syy` 强制刷新。
索引文件本身每次部署都是新内容，`curl -I` 能看到 `Cache-Control`。

**装完 `bongocat-x-bin` 但 Live2D 不显示。**
这是预期行为：Cubism Core 没随包分发。装 `live2d-sdk-nonfree`，或在设置 → 插件里手动导入。

**想重新发布当前版本。**
手动触发工作流并勾选 `force`：会把 `pkgrel` 加一，重新构建、重新签名、重新部署。

**换了签名密钥。**
删掉仓库的 `GPG_PRIVATE_KEY` secret 换成新的，然后用 `force` 触发一次；客户端需要重新
`pacman-key --add` + `--lsign-key` 新公钥（旧索引签名自然失效，这也是预期行为）。

**构建失败会通知我吗？**
GitHub 对计划任务失败会向仓库所有者发通知邮件，日志与 job summary 里包含失败原因、namcap
结果和包信息。