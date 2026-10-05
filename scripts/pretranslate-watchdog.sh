#!/bin/bash
# 预翻译守护脚本：worker 异常退出时自动重启并续跑；到截止时间后不再重启。
# 只用普通后台进程（nohup），不安装 launchd 项，不改系统设置。
#
# 用法：pretranslate-watchdog.sh <worker 可执行文件> <截止 HH:MM> [worker 其他参数…]
# 停止：touch "~/Library/Application Support/WikiOffline/pretranslate/stop"
export LC_ALL=en_US.UTF-8
WORKER="$1"; DEADLINE="${2:-07:00}"; shift 2
CTRL="$HOME/Library/Application Support/WikiOffline/pretranslate"
LOG="$HOME/Documents/维基百科离线/预翻译日志.txt"
mkdir -p "$CTRL"
rm -f "$CTRL/stop"
echo $$ > "$CTRL/watchdog.pid"

# 截止时间的绝对时间戳（若今天已过，则为明天）
now=$(date +%s)
dl=$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) $DEADLINE" +%s)
if [ "$dl" -le "$((now + 60))" ]; then dl=$((dl + 86400)); fi

stamp() { date "+%Y-%m-%d %H:%M:%S"; }
echo "$(stamp)  守护脚本启动（pid $$），截止 $(date -r $dl '+%m-%d %H:%M')" >> "$LOG"

fails=0
while true; do
  [ -f "$CTRL/stop" ] && { echo "$(stamp)  守护脚本：收到停止信号，退出" >> "$LOG"; break; }
  [ "$(date +%s)" -ge "$dl" ] && { echo "$(stamp)  守护脚本：已到截止时间，不再重启" >> "$LOG"; break; }
  start=$(date +%s)
  "$WORKER" --deadline "$DEADLINE" "$@" >> "$CTRL/worker-stdout.log" 2>&1 &
  wpid=$!
  echo $wpid > "$CTRL/worker.pid"
  wait $wpid
  code=$?
  dur=$(( $(date +%s) - start ))
  if [ $code -eq 0 ]; then
    echo "$(stamp)  守护脚本：worker 正常结束，退出" >> "$LOG"; break
  fi
  if [ $code -eq 3 ] || [ $code -eq 2 ]; then
    echo "$(stamp)  守护脚本：worker 前提不满足（代码 $code），不重启" >> "$LOG"; break
  fi
  if [ $dur -lt 60 ]; then fails=$((fails + 1)); else fails=0; fi
  if [ $fails -ge 5 ]; then
    echo "$(stamp)  守护脚本：worker 连续 5 次在 1 分钟内退出，放弃" >> "$LOG"; break
  fi
  wait_s=$(( 15 * (fails + 1) ))
  echo "$(stamp)  守护脚本：worker 异常退出（代码 $code，运行 ${dur}s），${wait_s}s 后重启" >> "$LOG"
  sleep $wait_s
done
rm -f "$CTRL/watchdog.pid" "$CTRL/worker.pid"
