#!/bin/bash

# 设置监控时间间隔、阈值和重置时间间隔
interval=5  # 监控时间间隔（秒）
threshold=90  # CPU 使用率阈值（百分比）
reset_interval=60  # 重置计数器的时间间隔（秒）

# 钉钉 Webhook URL
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=1a2457391815d5bcec7192d315e04a1816cd158329eaad5b76380441200a21e0"

# Elasticsearch 配置
elasticsearch_uri="http://192.168.3.231:9200"
index_name="cpu_usage_logs"

# Arthas 安装目录
arthas_install_dir="$(pwd)/arthas"

# 检查 Arthas 是否已安装
if [ ! -d "$arthas_install_dir" ]; then
  echo "Arthas is not installed. Installing Arthas..."
  # 下载 Arthas
  curl -O https://arthas.aliyun.com/arthas-boot.jar
  # 创建 Arthas 安装目录
  mkdir -p "$arthas_install_dir"
  # 移动 Arthas 到安装目录
  mv arthas-boot.jar "$arthas_install_dir"
  # 设置 Arthas 运行权限
  chmod +x "$arthas_install_dir/arthas-boot.jar"
fi

# 启动 Arthas
java -jar "$arthas_install_dir/arthas-boot.jar" &

# 获取 Java 应用的进程 ID 和主类
get_java_processes() {
  jps -l | awk '{print $1, $2}'
}

# 调用 Arthas 的 thread 命令
get_thread_stack_traces() {
  pid=$1
  arthas_output=$(java -jar "$arthas_install_dir/arthas-boot.jar" --attach $pid --command "thread -n 3")
  echo "$arthas_output"
}

# 发送钉钉消息
send_dingding_message() {
  message=$1
  curl -X POST -H "Content-Type: application/json" -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$message\"}}" "$webhook_url"
}

# 将日志写入 Elasticsearch
write_to_elasticsearch() {
  log=$1
  curl -X POST -H "Content-Type: application/json" -d "$log" "$elasticsearch_uri/$index_name/_doc"
}

# 生成唯一的 traceId
generate_trace_id() {
  trace_id=$(openssl rand -hex 16)
  echo "$trace_id"
}

# 获取所有 Java 应用的列表
java_processes=$(get_java_processes)

# 如果没有 Java 应用，则退出脚本
if [ -z "$java_processes" ]; then
  echo "No Java applications found. Exiting."
  exit 1
fi

# 显示所有 Java 应用的列表
echo "Java applications found:"
echo "$java_processes"
echo "Please enter the process ID of the Java application you want to monitor:"
read pid

# 检查输入的进程 ID 是否存在
if ! echo "$java_processes" | awk -v pid=$pid '{if ($1 == pid) exit 0; else exit 1}'; then
  echo "Invalid process ID. Exiting."
  exit 1
fi

# 获取应用名
app_name=$(echo "$java_processes" | awk -v pid=$pid '$1 == pid {print $2}')

# 输出当前获取的应用名
echo "Monitoring CPU usage of Java application: $app_name"

# 初始化计数器和时间戳
count=0
last_alert_time=$(date +%s)

# 循环监控
while true
do
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
      # 获取线程堆栈信息
      thread_stack_traces=$(get_thread_stack_traces $pid)
      # 将线程堆栈输出到文件
      output_file="arthas_output_$(date +"%Y%m%d%H%M%S").txt"
      echo "$thread_stack_traces" > $output_file
      echo "Thread stack traces saved to $output_file"
      # 生成唯一的 traceId
      trace_id=$(generate_trace_id)
      # 构建钉钉消息内容
      escaped_thread_stack_traces=$(echo "$thread_stack_traces" | head -n 50 | sed 's/"/\\\"/g')
      message="CPU Usage Alert\n\nCPU usage of Java app is $cpu_usage%\n\nTrace ID: $trace_id\n\nThread Stack Traces (first 50 lines):\n$escaped_thread_stack_traces"
      # 发送钉钉消息
      send_dingding_message "$message"
      # 构建日志数据
      escaped_thread_stack_traces=$(echo "$thread_stack_traces" | sed 's/"/\\"/g' | tr -d '\n')
      log="{\"message\":\"$message\",\"traceId\":\"$trace_id\",\"threadStackTraces\":\"$escaped_thread_stack_traces\"}"
      # 写入 Elasticsearch 日志
      write_to_elasticsearch "$log"
      count=$((count + 1))
      last_alert_time=$current_time
    fi
  fi
  # 等待指定时间间隔
  sleep $interval
done
