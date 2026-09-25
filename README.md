# BongoCat Arch Linux 软件源

用 GitHub Actions + Cloudflare Pages 搭起来的**全自动 Arch Linux 私有软件源**：上游
[BongoCat](https://github.com/vladelaina/BongoCat) 一发新版本，这里就会自动拉源码、编译成
pacman 包、用 GPG 签名、重建软件源索引，并推送到 Cloudflare Pages。

没有常驻服务器，不需要 R2，也不需要自己开机器：所有产物都是静态文件，靠 Pages 的全球 CDN
分发；实测单个包 3.6 MiB，远低于 Pages 每文件 25 MiB 的上限。

```
    上游 GitHub Release
            │  每 6 小时轮询 / 手动触发
            ▼
   ┌──────────────────┐        ┌───────────────────────────────┐
   │ detect 作业       │        │ GitHub Release（滚动存储）      │
   │ 解析最新 tag 与   │        │ arch-repo-store               │
   │ commit，决定是否  │        │  bongocat-*.pkg.tar.zst(+.sig)│
   │ 需要重建/重发布   │        └───────────────┬───────────────┘
   └────────┬─────────┘                        │ 取回全部包
            │ 有新版本                        │
            ▼                                  ▼
   ┌──────────────────────────────┐   ┌───────────────────────────┐
   │ build 作业（archlinux 容器）   │   │ publish 作业（archlinux）  │
   │ 非 root 用户 makepkg          │   │ repo-add --sign 重建索引   │
   │ Live2D Cubism SDK 官方下载    │──▶│ 用 pacman 自己验签校验     │
   │ 结构校验 + ldd 依赖校验        │   │ wrangler pages deploy     │
   │ 私钥签名后存入滚动存储         │   │ 提交 PKGBUILD 版本号       │
   └──────────────────────────────┘   └─────────────┬─────────────┘
                                                    ▼
                                    Cloudflare Pages（全球 CDN）
                                    https://<project>.pages.dev/x86_64
                                                    │
                                                    ▼
                                    开发机：pacman -Syu bongocat
```

## 客户端使用

一键配置（会先校验签名密钥指纹，再写入 `/etc/pacman.conf`）：

```bash
curl -fsSL https://<你的站点>/setup.sh | sudo bash
sudo pacman -S bongocat
```

手动配置等价于在 `/etc/pacman.conf` 末尾追加：

```ini
[bongocat]
SigLevel = Required DatabaseOptional
Server = https://<你的站点>/$arch
```

然后导入并本地签名仓库公钥（指纹见站点首页，务必核对）：

```bash
curl -fsSLO https://<你的站点>/bongocat-repo.asc
sudo pacman-key --add bongocat-repo.asc
sudo pacman-key --lsign-key <KEY_ID>
sudo pacman -Syu
```

`SigLevel = Required` 意味着**每个包都必须有有效签名**才会被安装，软件源索引也带签名；
`DatabaseOptional` 允许索引签名缺失时降级，但这里始终提供签名。

> 包是在滚动发行的 Arch 容器里编译的，可能依赖较新的 glibc / libstdc++。安装前先
> `pacman -Syu` 把系统更新到最新，这是 Arch 的常规做法。

## 仓库结构

| 路径 | 作用 |
| --- | --- |
| `PKGBUILD` | 从上游 release 源码构建 `bongocat`，含结构校验与依赖自检 |
| `.SRCINFO` | 由 PKGBUILD 生成，随版本号一起提交 |
| `repo-site/` | Pages 站点模板：首页、缓存策略 `_headers`、客户端脚本 `setup.sh` |
| `scripts/detect-upstream.sh` | 解析上游最新 release，决定重建/重发布 |
| `scripts/build-package.sh` | 构建 + 签名 + 产物校验（CI 与本地通用） |
| `scripts/assemble-repo.sh` | 从滚动存储取包、重建并签名索引、生成站点目录 |
| `scripts/verify-repo.sh` | 以客户端视角验证：pacman 同步 + 下载 + 验签 |
| `scripts/store-api.sh` | 滚动 Release 存储的 GitHub API 封装（上传/下载/清理） |
| `scripts/gpg.sh` | 无人值守签名所需的 GnuPG 配置与导入 |
| `scripts/set-pkgver.sh` | 更新 PKGBUILD 版本号并刷新 `.SRCINFO` |
| `scripts/publish-store.sh` | 上传产物到滚动存储并按保留数清理 |
| `scripts/common.sh` | 公共函数（日志、版本比较等） |
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
3. Pages 项目不用手动建，工作流首次发布会自动 `wrangler pages project create`。
   想用自定义域名（例如 `repo.example.com`）时，在 Pages 项目里加 Custom domain 即可，
   然后把 `SITE_URL` 变量指向它 —— 站点里生成的 `Server` 行和 `setup.sh` 都用这个地址。

### 3. 配置 Secrets 与 Variables

仓库 **Settings → Secrets and variables → Actions**：

| 类型 | 名称 | 说明 |
| --- | --- | --- |
| Secret | `GPG_PRIVATE_KEY` | 上一步的 `private.key` 全文（含 BEGIN/END 行） |
| Secret | `GPG_PASSPHRASE` | 可选，密钥口令；不设则按无口令密钥处理 |
| Secret | `CLOUDFLARE_API_TOKEN` | Pages 部署令牌 |
| Secret | `CLOUDFLARE_ACCOUNT_ID` | Cloudflare 账户 ID |
| Variable | `PAGES_PROJECT` | 可选，Pages 项目名，默认 `bongocat-arch` |
| Variable | `SITE_URL` | 可选，站点地址，默认 `https://<PAGES_PROJECT>.pages.dev` |
| Variable | `UPSTREAM_REPO` | 可选，上游仓库，默认 `vladelaina/BongoCat` |
| Variable | `KEEP_VERSIONS` | 可选，保留最近几个版本，默认 `3` |
| Variable | `STORE_TAG` | 可选，滚动存储用的 tag，默认 `arch-repo-store` |

### 4. 首次运行

推送到默认分支后，在 **Actions → Arch repository → Run workflow** 手动触发一次
（首次建议勾上 `force`），随后它会按每 6 小时的计划自动检查上游。

## 流水线做了什么

### 上游侦测（`detect`）

- 读取上游 `/releases/latest`（自动排除 prerelease 与 draft），解析 tag 与对应 commit；
- 与 `PKGBUILD` 里的 `pkgver` 比较：相同则**直接跳过**，不编译、不部署，避免无谓消耗；
- 顺带对比「滚动存储里最新的包」与「线上站点索引里的版本」，不一致就重发布 —— 上一次部署
  中断也不会让站点长期落后，下一次计划任务会自动修复；
- 手动 `workflow_dispatch` 可指定 `tag`（构建指定版本）或 `force`（同版本重打包，自动
  `pkgrel+1`，这样文件名与索引都指向新构建）。

### 构建与签名（`build`）

- 在 `archlinux:base-devel` 容器里，用非 root 的 `builder` 用户执行 `makepkg`
  （`makepkg` 明确拒绝 root 运行），依赖由工作流预先 `pacman -S` 装好，因此不需要 sudo；
- 构建参数对齐上游 release：`-DBONGO_CAT_REQUIRE_CUBISM=ON`（缺少 Live2D SDK 直接失败，
  而不是悄悄退化成无渲染的 diagnostic 后端）、Release 体积优化 + LTO；
- Live2D Cubism SDK for Native 与 GLEW 由 PKGBUILD 从**官方地址**下载并校验 SHA-256，
  和上游 CI 的做法一致（`vendor/CubismSdkForNative`）；
- 构建后立即自检：可执行文件存在、不是 diagnostic 后端、9 个必需资源文件齐全、
  `ldd` 无缺失库、**每个 `NEEDED` 的 so 都能在 `depends` 里找到归属包** —— 上游一旦引入新
  依赖，这里会直接失败，而不是发布一个装不上的包；
- 签名采用 git 之外的独立 `gpg --detach-sign`，产物与 `.sig` 一起上传到滚动 Release 存储；
- `namcap` 结果作为参考写进 job summary（不阻塞发布）。

### 索引与发布（`publish`）

- 从滚动 Release 取回全部历史包（按 `KEEP_VERSIONS` 清理更早的），一次性 `repo-add --sign`
  重建 `bongocat.db.tar.gz` 与 `bongocat.files.tar.gz` 并签名；
- `repo-add` 生成的 `.db`/`.db.sig`/`.files`/`.files.sig` 是**符号链接**，而 Pages 是对象
  存储、不提供符号链接，脚本会把它们替换成内容完全相同的真实文件（签名校验的是字节，
  因此依然有效），并断言部署目录里没有残留符号链接；
- 断言索引里出现的每个文件名和签名都真实存在于部署目录，避免发布出「索引指向 404」的坏源；
- 用 `pacman` 自己跑一遍客户端流程：临时 `GPGDir`/`DBPath`/`CacheDir` + `file://` 源，
  `pacman -Sy` 同步索引、`pacman -Si` 读元数据、`pacman -Sddw` 下载并按 `SigLevel = Required`
  验签 —— 任何签名或索引问题都会在这里拦住；
- `wrangler pages deploy` 推送整个目录（每次部署都是全量快照）；
- 部署成功后才把新版本号提交回 `PKGBUILD` 与 `.SRCINFO`；失败则保留旧版本号，让下一次计划
  任务重新构建并自愈。

### 为什么用 GitHub Release 做包存储

Cloudflare Pages 每次部署都是一份完整快照，没有「增量保留旧文件」的机制，所以必须有个地方
长久保存历史包。Release 资产天然适合：不占仓库体积、可审计、带 token 就能读写，还顺带成为
一个下载备份入口。清理旧包时同步删除 Release 资产和部署目录里的文件，两边始终一致。

## 本地构建与验证

本机是 Arch 时，可以直接跑完整流程：

```bash
# 只编译，产物自带全部结构校验与依赖校验
makepkg -f --noconfirm

# 或者用 CI 同款脚本（会顺带签名，需要一个可用的签名密钥）
GPG_PRIVATE_KEY="$(cat private.key)" scripts/build-package.sh --version 1.13.1 --out dist

# 组装部署目录（需要能访问滚动存储，即 GH_TOKEN + STORE_REPO）
GH_TOKEN=... STORE_REPO=owner/repo scripts/assemble-repo.sh --keep 3 --site-url https://example.pages.dev

# 以客户端视角验证产物：同步索引 + 下载 + 验签（需要 root 才能真正跑 pacman）
sudo scripts/verify-repo.sh --dir public
```

只看上游侦测结果、不碰任何远端状态：

```bash
scripts/detect-upstream.sh --repo vladelaina/BongoCat
```

## 设计与限制

- **X11 / XWayland，而不是原生 Wayland**：构建时显式 `-DSDL_WAYLAND=OFF`，与上游发布的
  Linux 二进制一致。桌面宠物需要绝对定位与逐像素输入穿透（XFixes），原生 Wayland 的
  xdg-shell 不允许客户端自行定位窗口，走 XWayland 反而行为正确。
- **构建结果不随构建机变化**：SDK 探测到的 `BONGO_CAT_HAS_WAYLAND_SHAPE` 分支只在原生
  Wayland 窗口下才可能执行，而 SDL 已是 X11-only，所以它必然是死代码。PKGBUILD 用一层
  `pkg-config` 包装把这个可选模块隐藏掉（PKGBUILD 内有说明），否则一台装了 `wayland`
  的开发机会在包里多链一个 `libwayland-client` 依赖，与上游 release 的配置也不一致。
- **上游源码 tarball 的哈希是 `SKIP`**：GitHub 的 tag 归档是按需重新打包的，哈希并不稳定，
  无法安全固定。作为替代，`build()` 会断言解压出来的 `CMakeLists.txt` 确实声明了 `$pkgver`
  （上游自己的发布流水线也是这么校验的），Live2D SDK 与 GLEW 则固定 SHA-256。
- **25 MiB 单文件上限**：构建脚本硬性检查产物大小，超限直接失败并说明原因（Pages 的每文件
  限制），避免发布出无法部署的包。
- **构建日志里的 `含有对 $srcdir 的引用` 警告是预期的**：上游用 `__FILE__` 记录日志位置，
  所以二进制里保留了构建路径（上游自己的 release 也一样）。想去掉的话，在 `build()` 的
  cmake 调用前加 `export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$srcdir=/usr/src/bongocat"`
  与同名 `CXXFLAGS`，代价是构建结果与本次已验证的产物不同（需重新验证）。
- **Cubism SDK 许可**：Live2D Cubism SDK for Native 是专有软件，遵循
  [Live2D Proprietary Software License Agreement](https://www.live2d.com/en/sdk/license/)，
  构建时从官方地址获取、不随本仓库分发；产物中静态链接了 Cubism Core，与上游 release 一致。
  本仓库自身的编排脚本以 MIT 授权（见 `LICENSE`）。
- **上游关系**：本仓库只是第三方自动化打包，与 BongoCat 作者无关；软件本身是 AGPL-3.0-only，
  模型资源为 MIT（见 `/usr/share/licenses/bongocat/`）。

## 常见问题

**站点起来了，但 `pacman -Sy` 报签名错误。**
先确认导入的是站点上的 `bongocat-repo.asc` 并且做过 `pacman-key --lsign-key`。用
`sudo pacman-key --finger <KEY_ID>` 核对指纹是否与站点首页一致。

**索引是旧的。**
`bongocat.db` 与 `bongocat.files` 的缓存是 300 秒，稍等或 `sudo pacman -Syy` 强制刷新。
索引文件本身每次部署都是新内容，`curl -I` 能看到 `Cache-Control`。

**想重新发布当前版本。**
手动触发工作流并勾选 `force`：会把 `pkgrel` 加一，重新构建、重新签名、重新部署。

**换了签名密钥。**
删掉仓库的 `GPG_PRIVATE_KEY` secret 换成新的，然后用 `force` 触发一次；客户端需要重新
`pacman-key --add` + `--lsign-key` 新公钥（旧索引签名自然失效，这也是预期行为）。

**构建失败会通知我吗？**
GitHub 对计划任务失败会向仓库所有者发通知邮件，日志与 job summary 里包含失败原因、namcap
结果和包信息。
