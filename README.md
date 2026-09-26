# Bring NAS-side HEIC/HEVC thumbnails back to Synology Photos on DSM 7.2.2+ — including HEIC from iOS 18+

```
ame-shim/   the shim: install-shim.sh, stub.sh
backlog/    repair items that already failed: run-batch.sh, commit-one.sh, gen-one.sh, config.sh
```

**English** · [中文](#中文让-synology-photos-在-dsm-722-上重新由-nas-生成-heichevc-缩略图含-ios-18-的-heic)

DSM 7.2.2 removed HEVC/HEIC decoding from the NAS. Since then Synology Photos cannot
generate thumbnails for HEIC photos or HEVC videos on the server; Synology tells you
to run *Image Assistant* on your computer instead. This guide puts the work back on
the NAS. It needs no Synology account, no downgrade, and changes no Synology file.

Tested on an x86_64 NAS running DSM 7.2.2-72806 Update 4 and Synology Photos 1.8.0-10070.
Other architectures and versions are untested.

## What it does

When Photos meets a HEIC photo or HEVC video, DSM's own thumbnailer
(`/usr/syno/bin/synothumb`, `synoflvconv`) looks for the *Advanced Media Extensions*
package and, if it finds these files, calls the package's own converter:

```
/var/packages/CodecPack/INFO
/var/packages/CodecPack/target/pack/HAS_HEVC
/var/packages/CodecPack/target/pack/usr/bin/convert   ← photos (ImageMagick CLI)
/var/packages/CodecPack/target/pack/bin/ffmpeg41       ← videos (one frame for the poster)
```

That package no longer decodes anything on DSM 7.2.2 (version 4.0 is a 5 MB stub). The shim
creates the two marker files and puts a small shell script at the two converter paths. The
script forwards each call to the open-source decoders from the SynoCommunity packages:

- `imagemagick` 7.1.2-14 or newer, which bundles libheif 1.20 and libde265 — it reads HEIC
  files from iOS 18 and later, which the libheif 1.12 shipped in DSM cannot even parse;
- `ffmpeg` 4.4, which extracts the poster frame and tone-maps HDR (HLG/PQ) video to SDR.

Photos then writes thumbnails and its database exactly as it would with a real codec pack.
No Synology binary is modified. No Synology HEVC decoder is used. The two license-check
programs in the package directory are stubs that log and return — in practice DSM never calls them.

The shim only accepts the "extract one frame" call for video. Any other ffmpeg call
(transcoding, for example) is logged and refused, so Photos cannot start heavy jobs behind your back.

## Requirements

- DSM 7.2.2 or later, x86_64. Advanced Media Extensions **not installed** (uninstall 4.0 if present).
- Package Center → Settings → Package Sources: add `https://packages.synocommunity.com`.
  Install **ImageMagick** (≥ 7.1.2-14) and **ffmpeg** from that source.
- SSH access and `sudo`.

## Install

```sh
# on the NAS: put this repository on a volume, e.g. /volume1/tools/
cd /volume1/tools/synology-photos-server-side-thumbnailgen/ame-shim
chmod +x *.sh
sudo ./install-shim.sh
```

The script refuses to run if a real Advanced Media Extensions package is present. It prints the
files it created. Logs go to `ame-shim/log/` (override with `SHIM_LOG=/path`).

Note: `/tmp` on DSM is mounted `noexec`; keep the scripts on a volume.

## Verify

Copy one HEIC and one HEVC `.MOV` into a Photos folder over SMB or File Station.
Within a few seconds the `@eaDir/<file>/` directory next to them should contain
`SYNOPHOTO_THUMB_SM.jpg`, `_M.jpg`, `_XL.jpg` owned by `root`, and Photos should show
the thumbnails. If you see `SYNOPHOTO_THUMB_*.fail` instead, look at:

```sh
tail ame-shim/log/calls.log            # FAIL / REFUSED / fallback lines
tail ame-shim/log/calls.log.stderr
grep synothumb /var/log/messages | tail   # DSM's own errors, with the full command line
```

## Photos and videos already in your library

The shim only affects files indexed after it is installed. Anything that failed before is
marked `status = 3` in the Photos database, and Photos **does not retry** those items —
neither "Re-index" in the settings nor `synofoto-bin-index-tool -t repair_undone` touches
them (tested). The scripts in [`backlog/`](backlog/) repair them: they generate the thumbnails
with the same SynoCommunity decoders, then write the three database fields Photos expects,
mirroring what the official client does.

> ⚠️ **This writes to Synology's private database. Read the scripts before running them.**
>
> **Check your Synology Photos version first** (Package Center → Installed, or
> `synopkg version SynologyPhotos`). The scripts were verified on **1.8.0-10070** only and
> refuse to write on any other version. Another version may store thumbnails differently;
> the scripts check that the columns and trigger they rely on still exist, but they cannot
> detect a change in meaning. On an unverified version the likely failure modes are thumbnails
> that Photos does not display, or ones it overwrites at the next re-index.
> If you decide to try anyway: `ALLOW_UNTESTED=1`, start with `--limit 1`, check that item in
> Photos in your browser, and use `--rollback` if it is wrong.

```sh
cd backlog
sudo PHOTOS_USER=<your DSM user> ./run-batch.sh --dry-run    # decode into work/stage only; writes nothing, works on any version
sudo PHOTOS_USER=<your DSM user> ./run-batch.sh --limit 12   # small trial; check the items in Photos
sudo PHOTOS_USER=<your DSM user> ./run-batch.sh              # the rest
sudo PHOTOS_USER=<your DSM user> ./commit-one.sh <id> --rollback   # undo one item
```

Safety nets: `run-batch.sh` dumps the two tables it writes before the first change, stops on
the first commit error, and skips anything the official client has already repaired;
`commit-one.sh` moves every `.fail` marker into `work/backup/<id>/` instead of deleting it.

## Uninstall

```sh
sudo ./install-shim.sh --off      # renames /var/packages/CodecPack, deletes nothing
```

## Caveats

- **Package Center lists "Advanced Media Extensions" as broken and offers to uninstall it.
  Do not uninstall it from there** — that removes the shim. If Package Center ever offers
  *Repair* or *Update* instead, do not click that either: it would install the real AME 4.0 over the shim.
  To remove the shim, use `install-shim.sh --off`.
- Survives reboots (verified across several).
- **DSM or Photos updates are untested.** After an update, copy one HEIC in and check.
  If it fails, run `install-shim.sh` again.
- Once the shim is present DSM routes **all** photo thumbnails, JPEG included, through it.
  If the SynoCommunity converter is missing or fails, the shim falls back to DSM's own
  `/usr/bin/convert`, so JPEG keeps working and only HEIC fails.
- The `convert` shim strips `-define jpeg:size=` from DSM's arguments (it makes ImageMagick 7
  mis-size the output) and uses the `convert` compatibility entry point, because DSM passes
  operators before the input file, IM6-style.
- HEVC is patent-encumbered. The shim uses libde265 from SynoCommunity; whether that is
  acceptable where you live is your call.

## Why not the other community fixes

- **Reinstalling AME 3.1 (007revad's script)** restores Synology's own HEVC decoder. It works for
  HEVC video and for HEIC taken before iOS 18. It cannot read HEIC from iOS 18 or later, because the
  bottleneck is DSM's libheif 1.12, not the decoder (see the script's issues #32 and #101).
- **FileBot / cron scripts** write `SYNOFILE_THUMB_*` for File Station. Photos uses different files
  and a database; they do not help Photos.
- **Downgrading DSM** to 7.2.1 works but you lose security updates.

## Credits

- SynoCommunity, and hgy59 for the ImageMagick package and its libheif update
  ([spksrc PR #6744](https://github.com/SynoCommunity/spksrc/pull/6744)).
- 007revad's [Video_Station_for_DSM_722](https://github.com/007revad/Video_Station_for_DSM_722)
  for documenting the `synopackageslimit.conf` and version-number tricks.
- strukturag/libheif [#1190](https://github.com/strukturag/libheif/issues/1190) for the iOS 18 root cause.

---

# 中文：让 Synology Photos 在 DSM 7.2.2+ 上重新由 NAS 生成 HEIC/HEVC 缩略图——含 iOS 18+ 的 HEIC

**[English](#bring-nas-side-heichevc-thumbnails-back-to-synology-photos-on-dsm-722--including-heic-from-ios-18)** · 中文

DSM 7.2.2 起群晖把 HEVC / HEIC 解码从 NAS 上拿掉了。Synology Photos 从此不能在服务端给 HEIC 照片和
HEVC 视频生成缩略图，官方让你在电脑上跑 *Image Assistant*。本文把这件事交还给 NAS：
不需要群晖账号，不降级，不改任何群晖自带文件。

实测环境：x86_64 机型，DSM 7.2.2-72806 Update 4，Synology Photos 1.8.0-10070。其他架构和版本未测。

## 原理

Photos 遇到 HEIC 或 HEVC 时，DSM 自己的缩略图程序（`/usr/syno/bin/synothumb`、`synoflvconv`）
会去找 *Advanced Media Extensions* 套件。只要下面这些文件在，它就调用套件自带的转换器：

```
/var/packages/CodecPack/INFO
/var/packages/CodecPack/target/pack/HAS_HEVC
/var/packages/CodecPack/target/pack/usr/bin/convert   ← 照片（ImageMagick 命令行）
/var/packages/CodecPack/target/pack/bin/ffmpeg41       ← 视频（抽一帧当封面）
```

DSM 7.2.2 上这个套件已经不解码了（4.0 版是个 5 MB 的空壳）。垫片建出两个标记文件，
在两个转换器的路径上放一个小 shell 脚本，把每次调用转交给 SynoCommunity 套件里的开源解码器：

- `imagemagick` 7.1.2-14 或更新，自带 libheif 1.20 和 libde265。它能读 iOS 18 之后的 HEIC，
  而 DSM 自带的 libheif 1.12 连文件都解析不了；
- `ffmpeg` 4.4，抽封面帧，HDR（HLG/PQ）视频先做色调映射。

之后 Photos 写缩略图、写数据库，和装了真编解码包时一模一样。不改群晖任何二进制，
不用群晖的 HEVC 解码器。套件目录里那两个授权检查程序是只记录、直接返回的替身——
实测 DSM 从来没调用过它们。

视频方面，垫片只接受「抽一帧」这一种调用。其他 ffmpeg 调用（比如转码）只记录并拒绝，
Photos 没法背着你在 NAS 上跑重活。

## 前提

- DSM 7.2.2 或更新，x86_64。**未安装** Advanced Media Extensions（装了 4.0 的先卸掉）。
- 套件中心 → 设置 → 套件来源：加 `https://packages.synocommunity.com`。
  从该来源安装 **ImageMagick**（≥ 7.1.2-14）和 **ffmpeg**。
- 能 SSH，能 `sudo`。

## 安装

```sh
# 在 NAS 上：把本仓库放到存储卷上，例如 /volume1/tools/
cd /volume1/tools/synology-photos-server-side-thumbnailgen/ame-shim
chmod +x *.sh
sudo ./install-shim.sh
```

目录里若装着真的 Advanced Media Extensions，脚本会拒绝执行。跑完它会列出建好的文件。
日志在 `ame-shim/log/`（用 `SHIM_LOG=/路径` 可改）。

注意：DSM 的 `/tmp` 挂载时禁止执行，脚本要放在存储卷上。

## 验证

通过 SMB 或 File Station 往 Photos 目录拷一张 HEIC 和一个 HEVC 的 `.MOV`。几秒之内，
旁边的 `@eaDir/<文件名>/` 里应出现属主为 `root` 的 `SYNOPHOTO_THUMB_SM.jpg`、`_M.jpg`、`_XL.jpg`，
Photos 里能看到缩略图。如果出现的是 `SYNOPHOTO_THUMB_*.fail`，看：

```sh
tail ame-shim/log/calls.log            # FAIL / REFUSED / fallback 行
tail ame-shim/log/calls.log.stderr
grep synothumb /var/log/messages | tail   # DSM 自己的报错，带完整命令行
```

## 你已经上传到 NAS 的 Synology Photos 里的照片 / 视频

垫片只影响装好之后才索引的文件。之前已经失败的文件在 Photos 数据库里标着 `status = 3`，
Photos **不会重试**它们——设置里的「重建索引」和 `synofoto-bin-index-tool -t repair_undone`
都不管这些（实测）。[`backlog/`](backlog/) 里的脚本负责修它们：用同一套 SynoCommunity 解码器
生成缩略图，再照官方客户端的做法写 Photos 数据库里的三处字段。

> ⚠️ **这会写群晖的私有数据库。跑之前先读脚本。**
>
> **先核对你的 Synology Photos 版本**（套件中心 → 已安装，或 `synopkg version SynologyPhotos`）。
> 脚本只在 **1.8.0-10070** 上验证过，遇到其他版本会拒绝写库。别的版本可能用不同方式存缩略图；
> 脚本会检查它依赖的列和触发器还在不在，但查不出「字段还在、含义变了」。在未验证的版本上，
> 可能的后果是 Photos 不显示生成的缩略图，或者下次重建索引时把它们覆盖掉。
> 执意要试：加 `ALLOW_UNTESTED=1`，先 `--limit 1`，去浏览器的 Photos 里看那一张，不对就 `--rollback`。

```sh
cd backlog
sudo PHOTOS_USER=<你的 DSM 用户名> ./run-batch.sh --dry-run    # 只解码到 work/stage，不写任何东西，任何版本都能跑
sudo PHOTOS_USER=<你的 DSM 用户名> ./run-batch.sh --limit 12   # 先试 12 个，去 Photos 里看
sudo PHOTOS_USER=<你的 DSM 用户名> ./run-batch.sh              # 剩下的
sudo PHOTOS_USER=<你的 DSM 用户名> ./commit-one.sh <id> --rollback   # 回滚单个文件
```

保险措施：`run-batch.sh` 在第一次写库前先导出它要改的两张表，遇到第一个提交错误就停，
已被官方客户端修好的自动跳过；`commit-one.sh` 把每个 `.fail` 标记挪到 `work/backup/<id>/` 而不是删掉。

## 卸载

```sh
sudo ./install-shim.sh --off      # 把 /var/packages/CodecPack 改名，不删任何东西
```

## 注意事项

- **套件中心会把「Advanced Media Extensions」列为损坏并提示卸载。别在那里点卸载**——那会把垫片删掉。
  如果它提示的是「修复」或「更新」，也别点：那会把真的 AME 4.0 装上，覆盖垫片。
  要移除垫片，用 `install-shim.sh --off`。
- 重启不影响（多次重启验证过）。
- **DSM 或 Photos 升级后未测。** 升级后拷一张 HEIC 进去看看；失败就再跑一次 `install-shim.sh`。
- 垫片就位后 DSM 会把**所有**照片（包括 JPEG）的缩略图都交给它。SynoCommunity 的转换器不在或失败时，
  垫片回落到 DSM 自带的 `/usr/bin/convert`，JPEG 照常，只有 HEIC 会失败。
- `convert` 替身会剔除 DSM 传来的 `-define jpeg:size=`（它让 ImageMagick 7 算错尺寸），
  并走 `convert` 兼容入口，因为 DSM 用的是 IM6 的老写法，操作参数写在输入文件前面。
- HEVC 有专利。垫片用的是 SynoCommunity 的 libde265，在你所在的地区是否合适，自己判断。

## 为什么不用社区已有的办法

- **装回 AME 3.1（007revad 的脚本）**恢复的是群晖自己的 HEVC 解码器。HEVC 视频和 iOS 18 以前的 HEIC 都行，
  iOS 18 之后的 HEIC 不行——卡点是 DSM 自带的 libheif 1.12，不是解码器（见该项目 issue #32、#101）。
- **FileBot / 定时脚本**写的是 File Station 用的 `SYNOFILE_THUMB_*`。Photos 用另一套文件加数据库，用不上。
- **把 DSM 降到 7.2.1** 能用，但没有安全更新。

## 致谢

- SynoCommunity 与 hgy59：ImageMagick 套件及其 libheif 升级
  （[spksrc PR #6744](https://github.com/SynoCommunity/spksrc/pull/6744)）。
- 007revad 的 [Video_Station_for_DSM_722](https://github.com/007revad/Video_Station_for_DSM_722)：
  `synopackageslimit.conf` 与版本号的处理方式。
- strukturag/libheif [#1190](https://github.com/strukturag/libheif/issues/1190)：iOS 18 问题的根因。
