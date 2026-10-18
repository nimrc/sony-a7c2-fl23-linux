#!/usr/bin/env bash
# A7C II (ILCE-7CM2) 2.01 FL2/FL3 预览版 —— Linux 一键脚本
#
# 只是上游 Windows 工具包（QAQLeonard/a7c2-fl23-research）的 Linux 外壳：
#   - 下载并校验固定版本的上游工具包，建 Python 环境，装 udev 规则
#   - 每次和相机通信前，按实测可行的顺序交接 USB：
#     让内核 usb-storage 先初始化相机 -> 卸载存储盘 -> 解绑接口
#   - 调用上游 app.py，不改上游代码，不自动重试任何写入
#
# 实验性质：改固件可能让相机无法开机。使用前请读 README。

set -euo pipefail

# ---------- 固定的上游版本 ----------
UPSTREAM_COMMIT=dd01c07a2a5df004d709595a43ebafe81bbd8fae
ZIP_NAME=a7c2-fl23-2.01-preview-0.1.0.zip
ZIP_URL="https://github.com/QAQLeonard/a7c2-fl23-research/raw/${UPSTREAM_COMMIT}/${ZIP_NAME}"
ZIP_SHA256=2bbbf3942f2e1b8439242ec7fae703009645a4533473bafa7b41f542e13c6c75

VID=054c
PID_MSC=0e8a
UDEV_RULE=/etc/udev/rules.d/70-sony-a7c2.rules
QUIRKS=/sys/module/usb_storage/parameters/quirks

A7C2_HOME=${A7C2_HOME:-$HOME/a7c2-fl23}
TOOLKIT=$A7C2_HOME/toolkit/a7c2_fl23_preview
PY=$TOOLKIT/.venv/bin/python
WORK=${A7C2_WORK:-$A7C2_HOME/work}
BACKUP=${A7C2_BACKUP:-$A7C2_HOME/backup}
LOGS=$A7C2_HOME/logs

# ---------- 输出 ----------
if [[ -t 1 ]]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B='' R='' G='' Y='' N=''; fi
info() { printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s警告:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s错误:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 " a; printf '%s' "$a"; }
confirm_word() { # $1 提示, $2 需要输入的词
  local a; a=$(ask "$1 请输入 ${B}$2${N} 继续，其他任意输入取消:")
  [[ $a == "$2" ]] || die "已取消。"
}

usage() {
  cat <<EOF
用法: $0 [命令]

  (不带参数)      引导式完整流程：setup -> prepare -> install
  setup           下载并校验工具包、建 Python 环境、装 udev 规则（不连相机）
  prepare         备份与检查（不写程序文件）
  install         安装预览版（会写入相机）
  verify          冷启动后核对程序文件和保存的参数
  restore         用本机备份还原官方原版
  status          显示工作区状态和相机 USB 身份
  gui             交接 USB 后打开上游图形界面

环境变量:
  A7C2_HOME    数据目录（默认 ~/a7c2-fl23），含 toolkit/ work/ backup/ logs/
  A7C2_BACKUP  第二份备份目录（默认 \$A7C2_HOME/backup，建议放到另一块盘）
  A7C2_WORK    工作区目录（默认 \$A7C2_HOME/work）
EOF
}

# ---------- setup ----------
pick_python() {
  if command -v uv >/dev/null; then echo uv; return; fi
  local p
  for p in python3.12 python3.13 python3.11 python3.10 python3; do
    if command -v "$p" >/dev/null && "$p" -c 'import sys; sys.exit(not (3,10)<=sys.version_info[:2]<=(3,13))' 2>/dev/null; then
      echo "$p"; return
    fi
  done
  command -v python3 >/dev/null && { warn "没找到 3.10-3.13 的 Python，改用 $(python3 -V)；依赖可能装不上，建议装 uv。"; echo python3; return; }
  die "需要 Python 3.10+（推荐装 uv：https://docs.astral.sh/uv/）。"
}

cmd_setup() {
  local need=()
  for c in curl unzip sha256sum lsblk udisksctl sudo; do command -v "$c" >/dev/null || need+=("$c"); done
  ((${#need[@]} == 0)) || die "缺少命令: ${need[*]}（Arch: sudo pacman -S curl unzip udisks2 util-linux）"

  mkdir -p "$A7C2_HOME/toolkit" "$LOGS"
  local zip=$A7C2_HOME/$ZIP_NAME
  if [[ ! -f $zip ]] || ! echo "$ZIP_SHA256  $zip" | sha256sum -c --status; then
    info "下载上游工具包（固定提交 ${UPSTREAM_COMMIT:0:7}）"
    curl -fL --progress-bar --retry 3 -o "$zip.part" "$ZIP_URL"
    mv "$zip.part" "$zip"
  fi
  echo "$ZIP_SHA256  $zip" | sha256sum -c --status || die "工具包 SHA-256 不符，已停止。删除 $zip 后重试。"
  info "工具包 SHA-256 校验通过"

  if [[ ! -f $TOOLKIT/app.py ]]; then
    unzip -q "$zip" -d "$A7C2_HOME/toolkit"
  fi

  if [[ ! -x $PY ]]; then
    local p; p=$(pick_python)
    info "创建 Python 环境（$p）"
    if [[ $p == uv ]]; then
      uv venv -q -p 3.12 "$TOOLKIT/.venv"
      uv pip install -q --python "$PY" -r "$TOOLKIT/requirements.txt"
    else
      "$p" -m venv "$TOOLKIT/.venv"
      "$PY" -m pip install -q -r "$TOOLKIT/requirements.txt"
    fi
  fi
  "$PY" -c 'import usb, Cryptodome, yaml, libusb_package' || die "Python 依赖不完整；删除 $TOOLKIT/.venv 后重跑 setup。"
  "$PY" -c 'import tkinter' 2>/dev/null || warn "Tkinter 不可用，gui 命令无法使用（Arch: sudo pacman -S tk）。命令行流程不受影响。"

  info "运行离线测试和工具包自检（不连相机）"
  (cd "$TOOLKIT" && "$PY" -m unittest discover -s tests >/dev/null 2>&1) || die "离线测试失败。"
  (cd "$TOOLKIT" && "$PY" app.py check-package)

  local rule
  rule=$(printf 'SUBSYSTEM=="usb", ATTR{idVendor}=="%s", ATTR{idProduct}=="%s", MODE="0660", TAG+="uaccess"\n' \
    "$VID" "$PID_MSC" "$VID" 0336)
  if [[ "$(cat "$UDEV_RULE" 2>/dev/null)" != "$rule" ]]; then
    info "安装 udev 规则 $UDEV_RULE（需要 sudo）"
    # 编号必须小于 73，否则排在 73-seat-late.rules 之后，uaccess 不生效
    printf '%s\n' "$rule" | sudo tee "$UDEV_RULE" >/dev/null
    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=$VID || true
  fi
  [[ -f /etc/udev/rules.d/99-sony-a7c2.rules ]] && warn "发现旧的 99-sony-a7c2.rules（编号太大不生效），可以删掉。"
  info "setup 完成。"
}

need_setup() { [[ -x $PY && -f $TOOLKIT/app.py && -f $UDEV_RULE ]] || die "请先运行: $0 setup"; }

# ---------- USB 交接 ----------
camera_dev() { # 输出 sysfs 设备名（如 3-3）和 PID；没有就返回 1
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor && $(<"$d/idVendor") == "$VID" ]] || continue
    echo "$(basename "$d") $(<"$d/idProduct")"; return 0
  done
  return 1
}

intf_driver() { local l; l=$(readlink "/sys/bus/usb/devices/$1/driver" 2>/dev/null) && basename "$l" || true; }

camera_disks() { # $1 = 接口名，如 3-3:1.0
  local b
  for b in /sys/block/sd*; do
    [[ -e $b ]] || continue
    [[ $(readlink -f "$b/device") == *"/$1/"* ]] && echo "/dev/$(basename "$b")"
  done
}

drop_quirk() {
  [[ -w $QUIRKS || -r $QUIRKS ]] || return 0
  local cur new
  cur=$(<"$QUIRKS")
  [[ $cur == *"$VID:$PID_MSC"* ]] || return 0
  new=$(tr ',' '\n' <<<"$cur" | { grep -v "^$VID:$PID_MSC:" || true; } | paste -sd, -)
  warn "检测到 usb-storage quirks 忽略了相机（$cur），这会导致 Sony 扩展命令超时，正在移除。"
  printf '%s' "$new" | sudo tee "$QUIRKS" >/dev/null
  return 1
}

wait_camera() {
  local i dev pid
  for ((i = 0; i < 300; i++)); do
    if read -r dev pid < <(camera_dev); then
      if [[ $pid == "$PID_MSC" ]]; then echo "$dev"; return 0; fi
      ((i % 10 == 0)) && warn "相机当前是 $VID:$pid，不是大容量存储身份 $PID_MSC。请把相机 USB 连接设为「大容量存储」后重新插线。" >&2
    else
      ((i % 10 == 0)) && info "等待相机连接（$VID:$PID_MSC）…" >&2
    fi
    sleep 1
  done
  return 1
}

# 实测可行的顺序：内核 usb-storage 先正常初始化相机 -> 卸载存储盘 -> 解绑接口。
# 直接让内核忽略相机（quirks）会让 Sony 扩展命令超时；不解绑则报 Resource busy。
attach_camera() {
  local attempt dev intf drv disk part mp node
  drop_quirk || {
    info "请拔掉相机 USB 线再插回去（保持大容量存储模式），然后按回车。"; read -r _
  }
  for attempt in 1 2; do
    dev=$(wait_camera) || die "5 分钟内没等到相机 $VID:$PID_MSC。"
    intf=$dev:1.0
    for _ in {1..10}; do [[ -e /sys/bus/usb/devices/$intf ]] && break; sleep 0.5; done
    drv=$(intf_driver "$intf")
    if [[ -z $drv ]]; then
      info "相机接口 $intf 还没被内核初始化，交给 usb-storage 初始化一次"
      printf '%s' "$intf" | sudo tee /sys/bus/usb/drivers/usb-storage/bind >/dev/null 2>&1 || true
      sleep 4
      drv=$(intf_driver "$intf")
    fi
    [[ $drv == usb-storage ]] && break
    [[ -z $drv && $attempt == 1 ]] && { info "初始化没成功。请拔掉相机 USB 线再插回去，然后按回车。"; read -r _; continue; }
    die "相机接口被意外的驱动占用: ${drv:-无}。"
  done

  for _ in {1..10}; do [[ -n $(camera_disks "$intf") ]] && break; sleep 0.5; done
  sync
  for disk in $(camera_disks "$intf"); do
    while read -r node mp; do
      [[ -n $mp ]] || continue
      info "卸载 $node（$mp）"
      udisksctl unmount -b "$node" >/dev/null 2>&1 || sudo umount "$node" || die "无法卸载 $node，请关闭正在访问相机存储卡的程序。"
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$disk")
  done
  sleep 1 # 桌面环境可能在卸载后又立刻重新挂载
  for disk in $(camera_disks "$intf"); do
    if lsblk -nro MOUNTPOINT "$disk" | grep -q .; then die "相机存储盘又被挂载了（$disk），请关闭自动挂载后重试。"; fi
  done

  info "把相机接口 $intf 从 usb-storage 解绑"
  printf '%s' "$intf" | sudo tee /sys/bus/usb/drivers/usb-storage/unbind >/dev/null
  sleep 1
  [[ -z $(intf_driver "$intf") ]] || die "解绑失败。"

  part=/sys/bus/usb/devices/$dev
  node=$(printf '/dev/bus/usb/%03d/%03d' "$(<"$part/busnum")" "$(<"$part/devnum")")
  [[ -r $node && -w $node ]] || die "当前用户没有 $node 的读写权限，udev 规则没生效；重新登录或重跑 setup。"
  CAMERA_PORT=$dev
  info "相机已就绪：USB 口 $dev，$VID:$PID_MSC"
}

# ---------- 工作区状态 ----------
state_get() { # $1 = python 表达式，s 为 state
  [[ -f $WORK/state.json ]] || return 0
  "$PY" -c "import json,sys; s=json.load(open(sys.argv[1])); v=$1; print('' if v is None else v)" "$WORK/state.json"
}

# install/verify 失败时，若操作日志一条都没新增、且失败发生在运行前的阶段，
# 说明连写入环节都没进入（install 的第一次写入之前一定先写日志），可以安全地把状态改回去。
recover_state() { # $1 = 运行前阶段, $2 = 运行前日志条数, $3 = 日志目录前缀
  local phase failed n
  phase=$(state_get "s['phase']"); failed=$(state_get "s.get('failed_during')"); n=$(state_get "len(s.get('journal',[]))")
  [[ $phase == needs_review && $failed == "$1" && $n == "$2" ]] || return 1
  cp "$WORK/state.json" "$3-state.json"
  "$PY" - "$WORK/state.json" "$1" <<'EOF'
import json, os, sys
p, phase = sys.argv[1], sys.argv[2]
s = json.load(open(p))
s['phase'] = phase
s.pop('last_error', None); s.pop('failed_during', None)
t = p + '.tmp'
with open(t, 'w', encoding='utf-8') as f:
    json.dump(s, f, ensure_ascii=False, indent=2); f.flush(); os.fsync(f.fileno())
os.replace(t, p)
EOF
  return 0
}

run_app() { # $1 = 命令, 其余参数传给 app.py
  local cmd=$1; shift
  local stamp log pre_phase pre_n rc
  stamp=$(date +%Y%m%d-%H%M%S); log=$LOGS/$stamp-$cmd
  mkdir -p "$LOGS"
  pre_phase=$(state_get "s['phase']"); pre_n=$(state_get "len(s.get('journal',[]))")
  local inhibit=()
  command -v systemd-inhibit >/dev/null && inhibit=(systemd-inhibit --what=sleep:idle:handle-lid-switch --why="A7C II $cmd")
  info "运行 app.py $cmd（日志: $log.log）"
  set +e
  (cd "$TOOLKIT" && "${inhibit[@]}" "$PY" -u app.py "$cmd" --workspace "$WORK" "$@") 2>&1 | tee "$log.log"
  rc=${PIPESTATUS[0]}
  set -e
  ((rc == 0)) && return 0

  echo
  printf '%s%s 没有完成。%s\n' "$R" "$cmd" "$N"
  local err; err=$(ls -t "$WORK"/evidence/*-error.txt 2>/dev/null | head -1 || true)
  [[ -n $err ]] && { cp "$err" "$log-traceback.txt"; echo "错误详情: $log-traceback.txt"; tail -n 3 "$err"; }
  case $cmd in
    install|verify)
      if [[ -n $pre_phase ]] && recover_state "$pre_phase" "$pre_n" "$log"; then
        echo
        info "操作日志没有新增任何记录，说明还没进入写入环节，相机没有被改动。"
        info "工作区状态已恢复为 $pre_phase（原状态文件备份在 $log-state.json）。"
        grep -q '服務身份未出現' "$log.log" && warn "相机认证后没切换成服务身份 0336。实测换一个 USB 口可以解决（这次用的是 $CAMERA_PORT 口）。"
        echo "下一步: 拔线，相机正常关机再开机，设为大容量存储后重新插上（必要时换 USB 口），再运行: $0 $cmd"
      else
        warn "这次失败可能已经进入写入环节。不要重跑写入，不要拔电池，保留 $WORK 和 $LOGS，先查清楚状态。"
      fi ;;
    *)
      warn "保留 $WORK 和 $LOGS，先查清楚原因，不要盲目重试。" ;;
  esac
  return "$rc"
}

read_battery() {
  local b; b=$(ask "相机当前实际电量（%，至少 50）:")
  [[ $b =~ ^[0-9]+$ ]] && ((b >= 50 && b <= 100)) || die "电量需要是 50-100 之间的整数。"
  echo "$b"
}

# ---------- 命令 ----------
cmd_prepare() {
  need_setup
  if [[ -d $WORK ]] && [[ -n $(ls -A "$WORK") ]]; then
    local phase; phase=$(state_get "s['phase']")
    [[ $phase == prepared || $phase == installed* ]] && die "工作区 $WORK 已经是 $phase 状态，不需要再 prepare。"
    local old; old=$LOGS/failed-$(date +%Y%m%d-%H%M%S)
    warn "工作区不是空的（状态: ${phase:-未知}），移到 $old 保存，换一个新的空工作区。"
    mkdir -p "$old"; mv "$WORK" "$old/work"
    [[ -d $BACKUP && -n $(ls -A "$BACKUP") ]] && mv "$BACKUP" "$old/backup"
  fi
  [[ -d $BACKUP && -n $(ls -A "$BACKUP") ]] && die "第二份备份目录 $BACKUP 不是空的。"
  mkdir -p "$WORK" "$BACKUP"
  [[ $(stat -c %d "$WORK") == $(stat -c %d "$BACKUP") ]] && warn "工作区和第二份备份在同一块盘上。prepare 完成后建议把 $BACKUP 再拷到 U 盘或网盘。"
  attach_camera
  run_app prepare --backup-copy "$BACKUP"
  info "prepare 完成：已备份并做了只读检查，相机没有被改动。"
}

cmd_install() {
  need_setup
  local phase; phase=$(state_get "s['phase']")
  [[ $phase == prepared ]] || die "工作区状态是「${phase:-无}」，需要先 prepare 成功（状态为 prepared）。"
  cat <<EOF

${B}即将写入相机固件。${N}
  - 这是实验预览版，只在少数机身上验证过；改固件有让相机无法开机的风险。
  - 安装期间不要碰相机和数据线，不要让电脑休眠。
  - 出错时不要直接重跑，脚本会告诉你是否安全。
EOF
  local battery; battery=$(read_battery)
  confirm_word "确认安装？" INSTALL
  attach_camera
  run_app install --battery-percent "$battery"
  cat <<EOF

${G}安装完成。${N}接下来在相机上：
  1. 拔掉 USB 线，正常关机，等存取灯熄灭。
  2. 拔电池等约 10 秒，装回后开机（只关开电源开关不够）。
  3. 菜单里应能看到 FL2、FL3。分别选中后用相机自带的重置功能，
     核对 对比度/高光/阴影/褪色/饱和度/锐度/锐度范围/清晰度 = 0,0,0,1,0,4,3,1
  4. 分别用 ST、FL2、FL3 拍几张并回放检查。
可选：之后重新连接，运行 $0 verify
EOF
}

cmd_verify() {
  need_setup
  [[ -f $WORK/state.json ]] || die "没有工作区 $WORK。"
  attach_camera
  run_app verify
}

cmd_restore() {
  need_setup
  [[ -f $WORK/state.json ]] || die "没有工作区 $WORK。"
  cat <<EOF

${B}即将用本机备份还原官方原版程序和 4 项设置。${N}
  还原前请先在相机上选回 ST，并做一次完整断电重启（关机、拔电池 10 秒、开机）。
EOF
  local battery; battery=$(read_battery)
  confirm_word "确认还原？" RESTORE
  attach_camera
  run_app restore --battery-percent "$battery"
  info "还原完成。拔线、正常关机、拔电池约 10 秒后开机，再检查拍照是否正常。"
}

cmd_status() {
  echo "数据目录: $A7C2_HOME"
  echo "工具包:   $([[ -f $TOOLKIT/app.py ]] && echo 已安装 || echo 未安装)"
  echo "udev:     $([[ -f $UDEV_RULE ]] && echo "$UDEV_RULE" || echo 未安装)"
  if [[ -f $WORK/state.json && -x $PY ]]; then
    echo "工作区:   $WORK"
    echo "  阶段:     $(state_get "s['phase']")"
    echo "  日志条数: $(state_get "len(s.get('journal',[]))")"
    local f; f=$(state_get "s.get('failed_during')"); [[ -n $f ]] && echo "  失败于:   $f"
  else
    echo "工作区:   无"
  fi
  local dev pid
  if read -r dev pid < <(camera_dev); then
    local note
    case $pid in
      0e8a) note="大容量存储（可以开始操作）" ;;
      0336) note="服务身份（工具正在通信）" ;;
      096f) note="待机/充电身份，请在相机上选大容量存储" ;;
      *) note="未知身份" ;;
    esac
    echo "相机:     $VID:$pid @ $dev — $note，接口驱动: $(intf_driver "$dev:1.0" || true)"
  else
    echo "相机:     未连接"
  fi
}

cmd_gui() {
  need_setup
  "$PY" -c 'import tkinter' 2>/dev/null || die "Tkinter 不可用（Arch: sudo pacman -S tk）。"
  attach_camera
  warn "GUI 每个按钮运行前都要重新交接 USB：某一步做完后关掉 GUI，再运行 $0 gui。"
  info "工作目录请填 $WORK，第二份备份填 $BACKUP"
  (cd "$TOOLKIT" && "$PY" gui.py)
}

cmd_all() {
  cmd_setup
  local phase; phase=$(state_get "s['phase']")
  if [[ $phase != prepared && $phase != installed* ]]; then
    echo; info "第 1 步：备份与检查。请把相机 USB 连接设为「大容量存储」，用数据线插到电脑上。"
    cmd_prepare
    phase=prepared
  fi
  if [[ $phase == prepared ]]; then
    echo; info "第 2 步：安装。"
    info "prepare 后相机需要重新连接：拔线，相机正常关机再开机，设为大容量存储后插回原来的 USB 口。"
    ask "重新插好后按回车:" >/dev/null
    cmd_install
  else
    info "工作区状态是 $phase，已经安装过。冷启动后可运行: $0 verify"
  fi
}

main() {
  [[ $EUID -ne 0 ]] || die "不要用 root 运行，脚本会在需要时调用 sudo。"
  case ${1:-} in
    "") cmd_all ;;
    setup) cmd_setup ;;
    prepare) cmd_prepare ;;
    install) cmd_install ;;
    verify) cmd_verify ;;
    restore) cmd_restore ;;
    status) cmd_status ;;
    gui) cmd_gui ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

CAMERA_PORT=unknown
main "$@"
