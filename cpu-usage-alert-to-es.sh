#!/bin/bash
# 默认配置参数
thread_count=10            #要显示的线程栈数
interval=5                 # 监控时间间隔（秒）
threshold=320              # CPU 使用率阈值（百分比）
message_push_threshold=400 # CPU 使用率阈值（百分比），消息推送
webhook_url="https://oapi.dingtalk.com/robot/send?access_token=49786f18c410e3a7aaf4c89ba30ff0be8844ae3360cc04b7bb928e18f6e16091"

SIT_ES_HOST="elasticsearch.erp-sit.yintaerp.com"
SIT_ES_PORT="443"
SIT_ES_USERNAME=""
SIT_ES_PASSWORD=""
SIT_ES_PROTOCOL="https"

PROD_ES_HOST="vpc-es-prod-txnopdywmougqakfx6kxtu4w5e.ap-east-1.es.amazonaws.com"
PROD_ES_PORT="443"
PROD_ES_USERNAME="yinta"
PROD_ES_PASSWORD="yintaES2019@!"
PROD_ES_PROTOCOL="https"

ES_HOST=""
ES_PORT=""
ES_USERNAME=""
ES_PASSWORD=""
ES_PROTOCOL=""

ES_INDEX_NAME="show_busy_java_threads_stack"

# 显示帮助
show_help() {
  echo "脚本使用说明:"
  echo "  必需选项:"
  echo "    -e, --env                           设置 env，支持sit、prod"
  echo "  可选选项:"
  echo "    -c, --thread_count <num>            设置要显示的线程栈数，（缺省5个）"
  echo "    -i, --interval <num>                设置监控时间间隔（秒），默认为 5"
  echo "    -t, --threshold <num>               设置 CPU 使用率阈值（百分比），默认为 320"
  echo "    -m, --message_push_threshold <num>  设置 CPU 使用率阈值（百分比），消息推送，默认为 400"
  echo "    -h, --help                          显示帮助信息"
}

# 检查是否传递了 access_key 和 secret_key
check_required_params() {
  if [[ -z "$env" ]]; then
    echo "错误: env 未提供"
    show_help
    exit 1
  fi
}
# 处理参数
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
  -e | --env)
    env="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -c | --thread_count)
    thread_count="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -i | --interval)
    interval="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -t | --threshold)
    threshold="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -m | --message_push_threshold)
    message_push_threshold="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -h | --help)
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

# 检查必需参数
check_required_params
# 使用配置参数进行其他操作
echo "env: $env"
echo "thread_count: $thread_count"
echo "interval: $interval"
echo "threshold: $threshold"
echo "threshold_message_push: $threshold_message_push"
echo "webhook_url: $webhook_url"

# 方法定义
# 检查 show-busy-java-threads 脚本是否存在，如果不存在则下载并设置执行权限
check_show_busy_java_threads() {
  if [ ! -f show-busy-java-threads ]; then
    curl -o show-busy-java-threads https://raw.githubusercontent.com/oldratlee/useful-scripts/dev-2.x/bin/show-busy-java-threads
    chmod +x show-busy-java-threads
  fi
}

# 检查环境
check_env() {
  if [[ "$(env)" == "prod" ]]; then
    ES_HOST="${PROD_ES_HOST}"
    ES_PORT="${PROD_ES_PORT}"
    ES_USERNAME="${PROD_ES_USERNAME}"
    ES_PASSWORD="${PROD_ES_PASSWORD}"
    ES_PROTOCOL="${PROD_ES_PROTOCOL}"
  else
    ES_HOST="${SIT_ES_HOST}"
    ES_PORT="${SIT_ES_PORT}"
    ES_USERNAME="${SIT_ES_USERNAME}"
    ES_PASSWORD="${SIT_ES_PASSWORD}"
    ES_PROTOCOL="${SIT_ES_PROTOCOL}"
  fi
  echo "当前ES环境：${env}"
  echo "Host：${ES_HOST}"
  echo "Port：${ES_PORT}"
  echo "UserName：${ES_USERNAME}"
  echo "Password：${ES_PASSWORD}"
  echo "Protocol：${ES_PROTOCOL}"
}

# 获取线程堆栈信息并上传至S3
get_thread_stack_traces() {
  pid=$1
  # 从所有运行的Java进程中找出最消耗CPU的线程（前10个），打印出其线程栈
  jstack_output=$(./show-busy-java-threads -p $pid -c ${thread_count} -l)
  echo "$jstack_output"
}

# 检查索引是否存在
check_index() {
  index_exists=$(curl -s -o /dev/null -w "%{http_code}" -u "${ES_USERNAME}:${ES_PASSWORD}" -X HEAD "${ES_PROTOCOL}://${ES_HOST}:${ES_PORT}/${ES_INDEX_NAME}")
  if [ "${index_exists}" == "200" ]; then
    echo "索引 ${ES_INDEX_NAME} 存在."
  else
    echo "索引 ${ES_INDEX_NAME} 不存在。正在创建索引..."
    create_index
  fi
}

# 创建索引
create_index() {
  curl -u "${ES_USERNAME}:${ES_PASSWORD}" -X PUT "${ES_PROTOCOL}://${ES_HOST}:${ES_PORT}/${ES_INDEX_NAME}" -H "Content-Type: application/json" -d '{
    "mappings": {
      "properties": {
        "cpuUsage": {
          "type": "double"
        },
        "appName": {
          "type": "keyword"
        },
        "timestamp": {
          "type": "date"
        },
        "ip": {
          "type": "ip"
        },
        "document": {
          "type": "keyword"
        },
        "originalFileName": {
          "type": "keyword"
        }
      }
    }
  }'

  if [ $? -eq 0 ]; then
    echo "索引 ${INDEX_NAME} 创建成功."
    upload_file
  else
    echo "创建索引失败 ${INDEX_NAME}."
    # 退出
    echo "正在退出。"
    exit 1
  fi
}

# 发送HTTP请求创建文档
createDocument() {
  # 检查索引是否存在
  check_index

  local file_path="$1"
  local file_name="$2"
  local cpu_usage="$3"
  local app_name="$4"

  # 读取文件内容
  file_content=$(cat "${file_path}")

  # 将文件内容格式化为JSON对象的值
  json_value=$(echo "${file_content}" | jq -Rs .)

  # 构建请求 URL
  url="${ES_PROTOCOL}://${ES_HOST}:${ES_PORT}/${ES_INDEX_NAME}/_doc"

  # 构建请求数据
  data='{
    "cpuUsage":"'"${cpu_usage}"'",
    "appName": "'"${app_name}"'",
    "timestamp": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'",
    "ip": "'"${container_ip}"'",
    "document": '"${json_value}"',
    "originalFileName": "'"${file_name}"'"
  }'

  printf "JSON内容\n%s\n" "$data"

  # 发送请求，并保存响应信息
  document_id=$(curl -s -u "${ES_USERNAME}:${ES_PASSWORD}" -X POST "${url}" -H "Content-Type: application/json" -d "${data}" | jq -r '._id')

  if [[ -n "$document_id" ]]; then
    echo "ES创建文档成功。"
    echo "文档ID：$document_id"
    echo "$document_id"
  else
    echo "ES创建文档失败。"
    echo ""
  fi

}

# 发送钉钉消息
send_dingding_message() {
  local message=$1
  local is_at_all=true
  local data="{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}, \"at\": {\"isAtAll\": $is_at_all}}"
  echo "send_dingding_message: $data"
  curl "$webhook_url" -H 'Content-Type: application/json' -d "$data"
}

# 获取应用名称
get_app_name() {
  pid=$1
  # 尝试获取 Skywalking 的应用名称
  app_name=$(ps -ef | grep java | grep -o '\-Dskywalking\.agent\.service_name=[^ ]*' | cut -d'=' -f2)

  # 如果未获取到应用名称，则使用 jps 获取启动类名称，并截取最后一个点后面的字符作为应用名称
  if [ -z "$app_name" ]; then
    main_class=$(jps -l | grep "${pid}" | awk '{print $2}')
    app_name=$(basename "$main_class" | cut -d '.' -f 2-)
  fi

  echo "$app_name"
}

# 获取容器IP
get_container_ip() {
  local container_ip

  # 检查操作系统类型
  if [[ "$(uname)" == "Darwin" ]]; then
    # 获取容器IP（适用于 macOS）
    container_ip=$(ifconfig | awk '/inet /{print $2; exit}')
  else
    # 获取容器IP（适用于其他操作系统）
    container_ip=$(hostname -I | awk '{print $1}')
  fi

  echo "$container_ip"
}

# 主逻辑
main() {
  # 检查 show-busy-java-threads 脚本是否存在
  check_show_busy_java_threads

  # 检查环境
  check_env

  # 检索索引
  check_index

  # 查找 Java 应用的进程 ID
  # pid=$(find_java_app_pid)

  echo "查找 Java 应用的进程 ID"

  # 尝试查找名为 app.jar 的 Java 应用的进程 ID
  pid=$(pgrep -f "app.jar")

  # 如果找到名为 app.jar 的 Java 应用
  if [ -n "$pid" ]; then
    echo "找到名为 app.jar 的 Java 应用，进程ID为 $pid"
  else
    # 获取所有Java应用的列表
    java_processes=$(jps -l)

    # 显示所有Java应用的列表
    echo "找到的Java应用程序："
    echo "$java_processes"

    # 提示用户选择要监视的Java应用程序的进程ID
    echo "请输入要监视的Java应用程序的进程ID："
    read pid

    # 检查输入的进程ID是否存在
    if ! echo "$java_processes" | grep -q "^$pid "; then
      echo "进程ID无效。"
      echo "运算结果：$?"
      echo "正在退出。"
      exit 1
    fi
  fi

  echo "Java应用的进程ID: $pid"

  # 获取容器IP
  container_ip=$(get_container_ip)
  echo "容器IP: $container_ip"

  # 获取应用名
  app_name=$(get_app_name "$pid")

  # 输出当前获取的应用名
  echo "开始监控Java应用程序的CPU使用率情况：$app_name"

  # 循环监控
  while true; do
    # 获取CPU使用率
    if [[ "$(uname)" == "Darwin" ]]; then
      cpu_usage=$(ps -o %cpu -p $pid | awk 'NR==2')
    else
      cpu_usage=$(top -b -n 1 -p $pid | awk '/^ *'$pid'/ {print $9}')
    fi

    # 将浮点数转换为整数
    int_cpu_usage=$(printf "%.0f" "$cpu_usage")
    echo "当前CPU使用率（整数）：$int_cpu_usage%，threshold：$threshold%"

    # 判断CPU使用率是否超过阈值
    if [ "$int_cpu_usage" -ge "$threshold" ]; then

      # CPU使用率超过阈值，输出线程堆栈信息并写入到ES
      echo "Java应用程序：$app_name（$pid）当前CPU使用率：($cpu_usage%)"

      # 获取线程堆栈信息
      # thread_stack_traces=$(cat "./_jstack_output_202401191115013N.txt")
      thread_stack_traces=$(get_thread_stack_traces $pid)

      # 打印线程堆栈信息
      echo "打印线程堆栈信息: $thread_stack_traces"

      # 获取当前时间（北京时间，用于显示和日志）
      display_time=$(TZ='Asia/Shanghai' date +"%Y-%m-%d %H:%M:%S.%3N")

      # 构建文件头部内容
      file_header_content="######################################################
# CPU Usage Alert
# 
# Current CPU Usage: $cpu_usage%
# Current App Name: $app_name
# Current Time: $display_time
# Container IP: $container_ip
######################################################"

      # 将线程堆栈输出到文件
      output_file="${app_name}_jstack_output_$(date +"%Y%m%d%H%M%S%3N").txt"

      # 将文件头部内容和线程堆栈信息写入输出文件
      echo "$file_header_content" >$output_file
      echo "$thread_stack_traces" >>$output_file
      echo "线程堆栈跟踪保存到： $output_file"

      # 从输出文件路径中提取文件名
      file_name="${output_file##*/}"

      # 调用 createDocument 方法
      result=$(createDocument "$output_file" "$file_name" "$cpu_usage" "$app_name")
      echo "result: $result"

      # 判断CPU使用率是否超过另一个阈值（消息推送）
      if [ "$int_cpu_usage" -ge "$message_push_threshold" ]; then

        # 转义特殊符号
        escaped_thread_stack_traces=$(echo "$thread_stack_traces" | sed 's/"/\\\"/g')

        # CPU使用率超过另一个阈值，发送钉钉提醒
        message="CPU Usage Alert\n\nCurrent CPU Usage: $cpu_usage%\n\nCurrent App Name: $app_name\n\nContainer IP: $container_ip\n\nCurrent Time: $display_time\n\nES Index Name: $ES_INDEX_NAME\n\nDocumentId: $result\n\nThread Stack Traces (first 25 lines):\n\n$(echo "$escaped_thread_stack_traces" | head -n 25)"
        # send_dingding_message "$message"
      fi
    fi

    sleep $interval
  done
}

# 执行主逻辑
main
