#!/bin/bash

# 默认配置参数
interval=5  # 监控时间间隔（秒）
threshold=320  # CPU 使用率阈值（百分比）
threshold_message_push=400  # CPU 使用率阈值（百分比），消息推送
bucket_name="yt-nas"  # 默认 bucket_name
region="ap-east-1"
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=49786f18c410e3a7aaf4c89ba30ff0be8844ae3360cc04b7bb928e18f6e16091"

# 显示帮助
show_help() {
  echo "脚本使用说明:"
  echo "  必需选项:"
  echo "    -a, --access-key     设置 access_key"
  echo "    -s, --secret-key     设置 secret_key"
  echo "  可选选项:"
  echo "    -i, --interval       设置监控时间间隔（秒），默认为 5"
  echo "    -t, --threshold      设置 CPU 使用率阈值（百分比），默认为 320"
  echo "    -m, --threshold-message-push 设置 CPU 使用率阈值（百分比），消息推送，默认为 400"
  echo "    -b, --bucket-name    设置 bucket_name，默认为 yt-nas"
  echo "    -h, --help           显示帮助信息"
}

# 处理参数
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
    -a|--access-key)
      access_key="$2"
      shift # 跳过参数值
      shift # 跳过参数名
      ;;
    -s|--secret-key)
      secret_key="$2"
      shift # 跳过参数值
      shift # 跳过参数名
      ;;
    -i|--interval)
      interval="$2"
      shift # 跳过参数值
      shift # 跳过参数名
      ;;
    -t|--threshold)
      threshold="$2"
      shift # 跳过参数值
      shift # 跳过参数名
      ;;
    -m|--threshold-message-push)
      threshold_message_push="$2"
      shift # 跳过参数值
      shift # 跳过参数名
      ;;
    -b|--bucket-name)
      bucket_name="$2"
      shift # 跳过参数值
      shift # 跳过参数名
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      # 未知选项
      echo "错误: 未知选项 $key"
      show_help
      exit 1
      ;;
  esac
done

# 使用配置参数进行其他操作
echo "access_key: $access_key"
echo "secret_key: $secret_key"
echo "interval: $interval"
echo "threshold: $threshold"
echo "threshold_message_push: $threshold_message_push"
echo "bucket_name: $bucket_name"
echo "region: $region"
echo "webhook_url: $webhook_url"

# 方法定义

# 检查 show-busy-java-threads 脚本是否存在，如果不存在则下载并设置执行权限
check_show_busy_java_threads() {
  if [ ! -f show-busy-java-threads ]; then
    curl -o show-busy-java-threads https://raw.githubusercontent.com/oldratlee/useful-scripts/dev-2.x/bin/show-busy-java-threads
    chmod +x show-busy-java-threads
  fi
}

# 获取Java应用的进程ID和主类
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

# 获取线程堆栈信息并上传至S3
get_thread_stack_traces() {
  pid=$1
  # 从所有运行的Java进程中找出最消耗CPU的线程（前10个），打印出其线程栈
  jstack_output=$(./show-busy-java-threads -p $pid -c 10)
  echo "$jstack_output"
}

# 发送HTTP请求上传文件
upload_file() {
  file_path=$1 # 获取文件
  file_name=$2 # 获取文件名

  # 获取当前日期，格式为年月日
  current_date=$(date +%Y%m%d)  
  # 构建签名字符串
  date=$(date -R)
  content_type="application/octet-stream"
  object_key="ops/thread_stack_traces/${current_date}/${file_name}"  # 设置对象的键，包括路径和文件名
  string_to_sign="PUT\n\n${content_type}\n${date}\n/${bucket_name}/${object_key}"
  signature=$(echo -en "${string_to_sign}" | openssl sha1 -hmac "${secret_key}" -binary | base64)
  
  # 上传
  curl -X PUT -T "$file_path" \
    -H "Host: ${bucket_name}.s3.${region}.amazonaws.com" \
    -H "Date: ${date}" \
    -H "Content-Type: ${content_type}" \
    -H "Authorization: AWS ${access_key}:${signature}" \
    "https://${bucket_name}.s3.${region}.amazonaws.com/${object_key}"

  # 返回object_key
  echo "$object_key"
}

# 发送钉钉消息
send_dingding_message() {
  local message=$1
  local is_at_all=true
  local data="{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}, \"at\": {\"isAtAll\": $is_at_all}}"
  echo "send_dingding_message: $data"
  curl "$webhook_url" -H 'Content-Type: application/json' -d "$data"
}

# 主逻辑


# 检查 show-busy-java-threads 脚本是否存在
check_show_busy_java_threads

# 获取所有Java应用的列表
java_processes=$(get_java_processes)

# 如果没有Java应用，则退出脚本
if [ -z "$java_processes" ]; then
  echo "未找到Java应用。退出脚本。"
  exit 1
fi

# 尝试查找名为 app.jar 的 Java 应用的进程 ID
pid=$(echo "$java_processes" | awk '/app\.jar/ {print $1}')

# 如果没有找到名为 app.jar 的 Java 应用
if [ -z "$pid" ]; then
  # 显示所有Java应用的列表
  echo "找到的Java应用程序："
  echo "$java_processes"
  echo "请输入要监视的Java应用程序的进程ID："
  read pid
fi

# 检查输入的进程ID是否存在
if ! echo "$java_processes" | awk -v pid=$pid '{if ($1 == pid) exit 0; else exit 1}'; then
  echo "进程ID无效。正在退出。"
  exit 1
fi

# 获取容器IP
container_ip=$(hostname -I | awk '{print $1}')

# 获取应用名
app_name=$(ps -ef | grep java | grep -o '\-Dskywalking\.agent\.service_name=[^ ]*' | cut -d'=' -f2)

# 输出当前获取的应用名
echo "开始监控Java应用程序的CPU使用率情况：$app_name"


# 循环监控
while true
do
  # 获取CPU使用率
cpu_usage=$(top -b -n 1 -p $pid | awk '/^ *'$pid'/ {print $9}')

# 将浮点数转换为整数
int_cpu_usage=$(printf "%.0f" "$cpu_usage")

echo "当前CPU使用率（整数）：$int_cpu_usage%，threshold：$threshold"

# 判断CPU使用率是否超过阈值
if [ "$int_cpu_usage" -ge "$threshold" ]; then
    
    # CPU使用率超过阈值，输出线程堆栈信息并上传至S3
    echo "Java应用程序$app_name（$pid）当前CPU使用率：($cpu_usage%)"
     
    # 获取线程堆栈信息
    thread_stack_traces=$(get_thread_stack_traces $pid)

    # 打印线程堆栈信息
    echo "打印线程堆栈信息: $thread_stack_traces"
    
    # 获取当前时间（北京时间，用于显示和日志）
    display_time=$(TZ='Asia/Shanghai' date +"%Y-%m-%d %H:%M:%S.%3N")

    # 构建文件头部内容
    file_header_content="######################################################
    # CPU Usage Alert
    # 
    # Current App Name: $app_name
    # Current CPU Usage: $cpu_usage%
    # Current Time: $display_time
    # Container IP: $container_ip
    ######################################################"    
    
    # 将线程堆栈输出到文件
    output_file="${app_name}_jstack_output_$(date +"%Y%m%d%H%M%S%3N").txt"
  
    # 将文件头部内容和线程堆栈信息写入输出文件
    echo "$file_header_content" > $output_file
    echo "$thread_stack_traces" >> $output_file
    echo "线程堆栈跟踪保存到： $output_file"

    # 从输出文件路径中提取文件名
    file_name="${output_file##*/}"
    
    # 上传线程堆栈信息文件到S3
    uploaded_object_key=$(upload_file "$file_path" "$file_name")

    # 判断CPU使用率是否超过另一个阈值（消息推送）
    if [ "$int_cpu_usage" -ge "$threshold_message_push" ]; then

      # 转义特殊符号
      escaped_thread_stack_traces=$(echo "$thread_stack_traces" | sed 's/"/\\\"/g')
     
      # CPU使用率超过另一个阈值，发送钉钉提醒
      message="CPU Usage Alert\n\nCPU usage of Java app is $cpu_usage%\n\nCurrent App Name: $app_name\n\nContainer IP: $container_ip\n\nCurrent Time: $display_time\n\nThread Stack Output File To S3 Object Key: $uploaded_object_key\n\nThread Stack Traces (first 50 lines):\n\n$(echo "$escaped_thread_stack_traces" | head -n 50)"
      send_dingding_message "$message"
    fi
  fi

  sleep $interval
done
