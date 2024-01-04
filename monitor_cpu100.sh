#!/bin/bash

# 设置监控时间间隔、阈值和重置时间间隔
interval=5  # 监控时间间隔（秒）
threshold=90  # CPU 使用率阈值（百分比）
reset_interval=60  # 重置计数器的时间间隔（秒）

# 钉钉 Webhook URL
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=1a2457391815d5bcec7192d315e04a1816cd158329eaad5b76380441200a21e0"

# 获取Java应用的进程ID和主类
get_java_processes() {
  jps -l | awk '{print $1, $2}'
}

# 获取CPU使用率
get_cpu_usage() {
  pid=$1
  pidstat -p $pid | awk 'NR==3 {print $7}'
}

# 获取线程堆栈信息
get_thread_stack_traces() {
  pid=$1
  jstack_output=$(jstack $pid)
  echo "$jstack_output" | awk '/nid=/{print; getline; print}'
}

# 发送钉钉消息
send_dingding_message() {
  message=$1
  curl -H "Content-Type: application/json" -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$message\"}}" "$webhook_url"
}

# 获取所有Java应用的列表
java_processes=$(get_java_processes)

# 如果没有Java应用，则退出脚本
if [ -z "$java_processes" ]; then
  echo "No Java applications found. Exiting."
  exit 1
fi

# 显示所有Java应用的列表
echo "Java applications found:"
echo "$java_processes"
echo "Please enter the process ID of the Java application you want to monitor:"
read pid

# 检查输入的进程ID是否存在
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
  cpu_usage=$(get_cpu_usage $pid)

  # 判断 CPU 使用率是否超过阈值
  if [[ -n $cpu_usage && $cpu_usage -ge $threshold ]]; then
    if [ $count -lt 2 ]; then
      echo "CPU usage of Java app is $cpu_usage%"

      # 获取线程堆栈信息
      thread_stack_traces=$(get_thread_stack_traces $pid)

      # 将线程堆栈输出到文件
      output_file="jstack_output_$(date +"%Y%m%d%H%M%S").txt"
      echo "$thread_stack_traces" > $output_file
      echo "Thread stack traces saved to $output_file"

      # 构建钉钉消息内容
      message="CPU Usage Alert\n\nCPU usage of Java app is $cpu_usage%\n\nTop 2 thread stack traces:\n\n$thread_stack_traces"

      # 发送钉钉消息
      send_dingding_message "$message"

      count=$((count + 1))
      last_alert_time=$current_time
    fi
  fi

  # 等待指定时间间隔
  sleep $interval
done
