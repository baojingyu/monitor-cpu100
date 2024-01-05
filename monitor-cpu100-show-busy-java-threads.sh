#!/bin/bash

# 检查 show-busy-java-threads 脚本是否存在，如果不存在则下载并设置执行权限
if [ ! -f show-busy-java-threads ]; then
  curl -o show-busy-java-threads https://raw.githubusercontent.com/oldratlee/useful-scripts/dev-2.x/bin/show-busy-java-threads
  chmod +x show-busy-java-threads
fi

# 设置监控时间间隔、阈值和重置时间间隔
interval=5  # 监控时间间隔（秒）
threshold=200  # CPU 使用率阈值（百分比）
reset_interval=60  # 重置计数器的时间间隔（秒）
message_interval=30  # 消息发送间隔（秒）

# 钉钉 Webhook URL
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=23a63c41aa35939693d917df7da776826a1fa6a65ca44041a3aa20bd8c47dbdd"

# Elasticsearch配置
elasticsearch_uri="http://192.168.3.231:9200"
index_name="cpu_usage_logs"

# 获取Java应用的进程ID和主类
# get_java_processes() {
#   jps -l | awk '{print $1, $2}'
# }
get_java_processes() {
  pids=$(pgrep -f java)
  for pid in $pids
  do
    cmd=$(ps -p $pid -o args=)
    if [[ $cmd == *"app.jar"* ]]; then
      echo $pid $cmd
    fi
  done
}

# 获取线程堆栈信息
get_thread_stack_traces() {
  pid=$1
  # 从所有运行的Java进程中找出最消耗CPU的线程（前3个），打印出其线程栈
  jstack_output=$(./show-busy-java-threads -p $pid -c 3)
  echo "$jstack_output"
}

# 发送钉钉消息
send_dingding_message() {
  local message=$1
  local is_at_all=true
  local data="{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}, \"at\": {\"isAtAll\": $is_at_all}}"
  echo "send_dingding_message: $data"
  curl "$webhook_url" -H 'Content-Type: application/json' -d "$data"
}

# 将日志写入Elasticsearch
write_to_elasticsearch() {
  log=$1
  curl -X POST -H "Content-Type: application/json" -d "$log" "$elasticsearch_uri/$index_name/_doc"
}

# 获取所有Java应用的列表
java_processes=$(get_java_processes)


# 如果没有Java应用，则退出脚本
if [ -z "$java_processes" ]; then
  echo "No Java applications found. Exiting."
  exit 1
fi

# 尝试查找名为 app.jar 的 Java 应用的进程 ID
pid=$(echo "$java_processes" | awk '/app\.jar/ {print $1}')

# 如果没有找到名为 app.jar 的 Java 应用
if [ -z "$pid" ]; then
  # 显示所有Java应用的列表
  echo "Java applications found:"
  echo "$java_processes"
  echo "Please enter the process ID of the Java application you want to monitor:"
  read pid
fi

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
while true
do
  # 获取当前时间（北京时间）
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
      echo "thread_stack_traces: $thread_stack_traces"

      # 将线程堆栈输出到文件
      output_file="jstack_output_$(date +"%Y%m%d%H%M%S").txt"
      echo "$thread_stack_traces" > $output_file
      echo "Thread stack traces saved to $output_file"
     
      # 获取当前时间（北京时间，用于显示和日志）
      display_time=$(TZ='Asia/Shanghai' date +"%Y-%m-%d %H:%M:%S")
      
      # 获取容器IP
      container_ip=$(hostname -I | awk '{print $1}')

      # 转义特殊符号
      escaped_thread_stack_traces=$(echo "$thread_stack_traces" | sed 's/"/\\\"/g')
     
      # 构建钉钉消息内容
      message="CPU Usage Alert\n\nCPU usage of Java app is $cpu_usage%\n\nContainer IP: $container_ip\n\nCurrent Time: $display_time\n\nThread Stack Traces (first 200 lines):\n\n$(echo "$escaped_thread_stack_traces" | head -n 200)"
      
      # 发送钉钉消息
      send_dingding_message "$message"

      # 构建日志数据
      # log="{\"message\":\"$message\",\"threadStackTraces\":\"$escaped_thread_stack_traces\",\"cpuUsage\":\"$cpu_usage\",\"currentTime\":\"$display_time\"}"
      
      # escaped_thread_stack_traces_log=$(printf '%s' "$thread_stack_traces" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\b/\\b/g; s/\f/\\f/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g')

      # 构建日志数据
      # log="{\"message\":\"$escaped_message\",\"threadStackTraces\":\"$escaped_thread_stack_traces_log\",\"cpuUsage\":\"$cpu_usage\",\"containerIP\":\"$container_ip\",\"currentTime\":\"$display_time\"}"

      # 写入Elasticsearch日志
      # write_to_elasticsearch "$log"

      count=$((count + 1))
      last_alert_time=$current_time
    elif [ $count -eq 2 ]; then
      # 获取当前时间与上一次发送消息的时间差
      message_elapsed_time=$((current_time - last_alert_time))

      # 如果时间差大于等于消息发送间隔，则重置计数器和上次发送消息的时间
      if [ $message_elapsed_time -ge $message_interval ]; then
        count=1
        last_alert_time=$current_time
      fi
    fi
  fi

  # 等待指定时间间隔
  sleep $interval
done
