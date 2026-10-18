# Sony A7C II FL2/FL3 —— Linux 一键脚本

[English](./README.md) | 简体中文

在 **Linux** 上给 **Sony A7C II（ILCE-7CM2）2.01 固件**装上 FL2 / FL3 两种照片 Creative Look，全程不需要 Windows。

本仓库只包含一个 Bash 脚本和文档。移植工作、固件补丁和安装工具全部来自 [QAQLeonard/a7c2-fl23-research](https://github.com/QAQLeonard/a7c2-fl23-research)。脚本只是把那套 Windows 工具包搬到 Linux 上跑，并解决 Linux 特有的 USB 问题，**不修改上游任何代码**。

> [!WARNING]
> **这是实验性质的非官方固件修改，可能让相机无法开机。**
> 上游预览版只在很少的机身上验证过；这个 Linux 流程在 1 台 A7C II（Arch Linux）上完整跑通过。
> 备份和回读只能发现错误，不能保证一定救得回来。风险自负，和 Sony 无关。

## 实测情况

| 项目 | 结果 |
|---|---|
| 系统 | Arch Linux（Omarchy），内核 7.x，Python 3.12（uv 建的环境） |
| 相机 | 1 台 ILCE-7CM2，固件 2.01 |
| prepare / install | 程序写入后完整读回，哈希和预期一致；设置写入、保存后读回一致 |
| 冷启动后 | FL2、FL3 出现在菜单里，能选中、能拍照 |
| 没测过 | 其他发行版、第二台机身、`verify` / `restore` 在 Linux 上的实际运行 |

## 快速开始

```bash
git clone https://github.com/nimrc/sony-a7c2-fl23-linux.git
cd sony-a7c2-fl23-linux
./a7c2-fl23.sh            # 引导式：setup -> prepare -> install
```

也可以分步运行：

```bash
./a7c2-fl23.sh setup      # 下载并校验工具包、建 Python 环境、装 udev 规则（不连相机）
./a7c2-fl23.sh prepare    # 备份与检查（不写程序文件）
./a7c2-fl23.sh install    # 安装（会写入相机）
./a7c2-fl23.sh verify     # 冷启动后核对（可选）
./a7c2-fl23.sh restore    # 用本机备份还原官方原版
./a7c2-fl23.sh status     # 查看工作区状态和相机 USB 身份
```

数据默认放在 `~/a7c2-fl23/`：

| 目录 | 内容 |
|---|---|
| `toolkit/` | 上游工具包和 Python 环境 |
| `work/` | 工作区：本机原始程序、设置备份、操作日志。**以后还原全靠它** |
| `backup/` | 第二份备份。建议用 `A7C2_BACKUP=/另一块盘/路径` 放到别的盘上 |
| `logs/` | 每次运行的完整输出和失败时的证据 |

## 准备

- **相机**：A7C II，固件 2.01。工具会核对相机里程序文件的哈希，版本不对会拒绝继续。电量至少 50%。
- **USB**：用支持数据传输的线直接连电脑，不要经过 Hub。相机菜单里的 USB 连接方式设为 **大容量存储（Mass Storage）**。
- **系统**：`bash`、`curl`、`unzip`、`udisks2`（`udisksctl`）、`sudo`，Python 3.10–3.13，或者装了 [uv](https://docs.astral.sh/uv/)（推荐）。用 GUI 的话还要 Tkinter（Arch: `sudo pacman -S tk`）。
- **不需要** Zadig，也不需要 Windows 驱动。

## 完整流程

1. **setup**：从上游仓库的固定提交下载 `a7c2-fl23-2.01-preview-0.1.0.zip`，校验 SHA-256（`2bbbf394…6c75`），建 Python 环境，跑上游离线测试，安装 udev 规则 `/etc/udev/rules.d/70-sony-a7c2.rules`。
2. **prepare**：插上相机。脚本交接好 USB 后运行上游的 `prepare`：读取并备份相机的原始程序和设置（两份），在电脑上生成补丁后的候选文件，再在相机上做只读检查。**这一步不改相机。**
3. **重新连接**：拔线，相机正常关机再开机，设为大容量存储后**插回同一个 USB 口**。
4. **install**：输入实际电量，再输入 `INSTALL` 确认。脚本运行上游的 `install`，大约 1 分钟，期间不要碰相机和数据线，脚本会阻止电脑休眠。
5. **冷启动**：拔线 → 正常关机，等存取灯熄灭 → **拔电池约 10 秒** → 装回开机。只关开电源开关，新效果不会出现。
6. **检查**：菜单里应能看到 FL2、FL3。分别选中后用相机自带的重置功能，核对 8 个参数（对比度、高光、阴影、褪色、饱和度、锐度、锐度范围、清晰度）是否为 `0, 0, 0, 1, 0, 4, 3, 1`。再分别用 ST、FL2、FL3 拍几张并回放。

## Linux 上踩过的坑（脚本已处理）

上游工具包只在 Windows 上测过。在 Linux 上直接跑会遇到下面几个问题：

| 现象 | 原因 | 脚本的处理 |
|---|---|---|
| `[Errno 16] Resource busy` | 内核 `usb-storage` 驱动占着相机接口。PMCA 原本会在 `UsbBackend.reset()` 里卸载内核驱动，但上游 `transport.py` 的 `Bounded` 类覆盖了 `reset()`，这一步被跳过了（Windows 上 Zadig 已换掉驱动，所以不受影响） | 每次运行前，把相机接口从 `usb-storage` 上解绑 |
| `[Errno 110] Operation timed out`，卡在读取相机型号 | 用 `usb_storage` 的 quirks（`054c:0e8a:i`）让内核忽略相机后，相机能响应标准存储命令，但 Sony 扩展命令会超时。看起来相机需要先被内核按普通存储设备初始化一次 | **不用** quirks；让内核先正常初始化并挂载相机，卸载存储盘后再解绑。发现残留的 quirks 会自动移除 |
| udev 规则不生效，设备只有 root 能访问 | 规则文件编号是 99，排在 `73-seat-late.rules` 之后，`uaccess` 不会生效 | 规则文件用 `70-` 开头 |
| `服務身份未出現`，相机认证后变成 `054c:0d68` 而不是 `0336` | 和 USB 口有关：同一台电脑的另一个口就正常 | 失败时提示换 USB 口 |

## 出错了怎么办

**不要直接重跑写入。** 脚本也从不自动重试。

- **install / verify 失败，且操作日志一条都没新增**：说明连认证或会话建立都没完成，还没进入写入环节（上游 install 在第一次写入前一定会先记一条日志），相机没被改动。脚本会自动把工作区状态改回原来的阶段，并备份原状态文件。照提示拔线、相机关机再开机，必要时换个 USB 口，然后重跑同一条命令即可。
- **其他情况**：脚本会提示“可能已经进入写入环节”。这时不要重跑、不要拔电池，保留 `~/a7c2-fl23/work` 和 `logs/`，先弄清楚状态。可以去上游仓库提 issue，附上日志，但**不要附 `*.private.bin`**，里面是相机的私人设置。
- **prepare 失败**：脚本会把旧工作区和备份挪到 `logs/failed-时间戳/` 保存，再用新的空目录重来。

## 还原官方原版

先在相机上选回 ST，做一次完整冷启动（关机、拔电池 10 秒、开机），再连接电脑：

```bash
./a7c2-fl23.sh restore
```

还原只能用**同一台机身**的 `work/` 目录。还原完成后再做一次冷启动。

## 隐私

`work/`、`backup/` 和 `logs/` 里有相机的设置备份（`*.private.bin`），日志里可能有序列号的哈希。**不要上传或公开这些文件。**

## 致谢与来源

- [QAQLeonard/a7c2-fl23-research](https://github.com/QAQLeonard/a7c2-fl23-research)：A7C II 2.01 FL2/FL3 移植、预览版工具包和全部研究文档。本仓库依赖其固定提交 `dd01c07`。
- [lzh2016zzz/a7cr-fl23-research](https://github.com/lzh2016zzz/a7cr-fl23-research)、[YuuLuo/a7c2-service-preload](https://github.com/YuuLuo/a7c2-service-preload)、[ma1co/Sony-PMCA-RE](https://github.com/ma1co/Sony-PMCA-RE)：上游工作所依据的研究。
- Sony 商标和固件数据权利归各自权利人所有。本仓库不包含任何 Sony 固件，也不重新分发上游工具包。

## 许可

- `a7c2-fl23.sh`：MIT，见 [LICENSE](./LICENSE)。
- 本 README：[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)，部分内容整理自上游文档。
- 上游工具包遵循其自带的 `LICENSE`、`NOTICE.md` 和 `licenses/`。
