#!/bin/bash

# 设置监控时间间隔、阈值和重置时间间隔
interval=5  # 监控时间间隔（秒）
threshold=90  # CPU 使用率阈值（百分比）
reset_interval=60  # 重置计数器的时间间隔（秒）

# 钉钉 Webhook URL
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=1a2457391815d5bcec7192d315e04a1816cd158329eaad5b76380441200a21e0"

# 获取 Java 应用的进程 ID
pid=$(jps | awk 'BEGIN{IGNORECASE=1} /app.jar/{print $1}')  # 匹配带有 "app.jar" 的应用

# 如果没有匹配项，则退出脚本
if [ -z "$pid" ]; then
  echo "No Java application found with 'app.jar'. Exiting."
  exit 1
fi

# 获取应用名
app_name=$(jps | awk -v pid=$pid 'BEGIN{IGNORECASE=1} $1==pid{print $2; exit}')

# 输出当前获取的应用名
echo "Monitoring CPU usage of Java application: $app_name"

# 初始化计数器和时间戳
count=0
last_alert_time=$(date +%s)

# 循环监控
while true; do
  # 获取当前时间
  current_time=$(date +%s)

  # 计算时间差
  elapsed_time=$((current_time - last_alert_time))

  # 如果时间差大于等于重置时间间隔，则重置计数器
  if [ $elapsed_time -ge $reset_interval ]; then
    count=0
    last_alert_time=$current_time
  fi

  # 获取 CPU 使用率
  cpu_usage=$(top -b -n 1 -p $pid | awk -v threshold=$threshold 'NR>7 { if ($1 == pid) { if ($9 >= threshold) print $9 } }' pid=$pid)

  # 判断 CPU 使用率是否超过阈值
  if [[ -n $cpu_usage ]]; then
    if [ $count -lt 2 ]; then
      echo "CPU usage of Java app is $cpu_usage%"

      # 使用 jstack 工具获取线程堆栈
      jstack_output=$(jstack $pid)

      # 获取前两个线程的堆栈
      top_2_threads=$(echo "$jstack_output" | awk '/nid=/{print; getline; print}')

      # 将线程堆栈输出到文件
      output_file="jstack_output_$(date +"%Y%m%d%H%M%S").txt"
      echo "$jstack_output" > $output_file
      echo "Thread stack traces saved to $output_file"

      # 构建钉钉消息内容
      message="### CPU Usage Alert\n\nCPU usage of Java app is $cpu_usage%\n\n**Top 2 thread stack traces:**\n\n\`\`\`\n$top_2_threads\n\`\`\`"

      # 发送钉钉消息
      curl -H "Content-Type: application/json" -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"CPU Usage Alert\",\"text\":\"$message\"}}" $webhook_url

      count=$((count + 1))
      last_alert_time=$current_time
    fi
  fi

  # 等待指定时间间隔
  sleep $interval
done
