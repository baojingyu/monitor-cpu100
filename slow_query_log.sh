#!/bin/bash
source /etc/profile

echo "start download aws mysql slow logs"
databases_list=(aurora-erp-mysql aurora-tms-mysql aurora-bi-mysql)
dtime=$(date -u +%F)
num="$(expr $(date -u +%H) - 1)"
logdir="/usr/local/filebeat/logs"

env=""     # 默认空
log_num=5 # 默认统计5条慢查询日志
webhook_url="https://oapi.dingtalk.com/robot/send?access_token="
access_token_team="98511d8d98a5f42af7c0e024780dd73df87925fc33a7b516d6f0b0d1342be67d" # 产研中心群
access_token="0d53b78985b674a88d61c3a24de4b98a9ea73c03f2d12ef032754b3f6c81994c" # 应用负责人群
# access_token="49786f18c410e3a7aaf4c89ba30ff0be8844ae3360cc04b7bb928e18f6e16091"

# 定义白名单用户
declare -a user_array=("dwh_ro" "dwh_rw" "ydp_system")

awsAccessKeyId=""
awsSecretAccessKey=""

SIT_ES_HOST="192.168.3.232"
SIT_ES_PORT="9200"
SIT_ES_USERNAME=""
SIT_ES_PASSWORD=""
SIT_ES_PROTOCOL="http"
SIT_KIBANA_URL="http://kibana.erp-sit.yintaerp.com/app/discover"
SIT_KIBANA_INDEX_UUID="918f8520-c3d0-11ee-8da6-ff08b6ea4a08"

PROD_ES_HOST="10.0.139.96"
PROD_ES_PORT="9200"
PROD_ES_USERNAME=""
PROD_ES_PASSWORD=""
PROD_ES_PROTOCOL="http"
PROD_KIBANA_URL="http://kibana.aws.yintaerp.com/app/discover"
PROD_KIBANA_INDEX_UUID="7bcb1f20-c3cf-11ee-a40f-37738685dfb3"

ES_HOST=""
ES_PORT=""
ES_USERNAME=""
ES_PASSWORD=""
ES_PROTOCOL=""
KIBANA_URL=""
KIBANA_INDEX_UUID=""

ES_INDEX_NAME="slow_query_log"

# 显示帮助
show_help() {
  echo "脚本使用说明:"
  echo "  必需选项:"
  echo "    -env, --env                                               设置 env，支持sit、prod"
  echo "  可选选项:"
  echo "    -awsAccessKeyId, --awsAccessKeyId                         设置awsAccessKeyId"
  echo "    -awsSecretAccessKey, --awsSecretAccessKey                 设置awsSecretAccessKey"
  echo "    -log_num, --log_num                                       设置慢查询日志条数，（缺省：5条）"
  echo "    -access_token, --access_token                             设置钉钉机器人访问令牌，（缺省：应用负责人群）"
  echo "    -help, --help                                             显示帮助信息"
}

# 检查是否传递了
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
  -access_token | --access_token)
    access_token="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -env | --env)
    env="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -awsAccessKeyId | --awsAccessKeyId)
    awsAccessKeyId="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -awsSecretAccessKey | --awsSecretAccessKey)
    awsSecretAccessKey="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -log_num | --log_num)
    log_num="$2"
    shift # 跳过参数值
    shift # 跳过参数名
    ;;
  -help | --help)
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

# 检查环境并设置配置
check_env() {
  if [[ "${env}" == "prod" ]]; then
    ES_HOST="${PROD_ES_HOST}"
    ES_PORT="${PROD_ES_PORT}"
    ES_USERNAME="${PROD_ES_USERNAME}"
    ES_PASSWORD="${PROD_ES_PASSWORD}"
    ES_PROTOCOL="${PROD_ES_PROTOCOL}"
    KIBANA_URL="${PROD_KIBANA_URL}"
    KIBANA_INDEX_UUID="${PROD_KIBANA_INDEX_UUID}"

    if [[ -n "$awsAccessKeyId" && -n "$awsSecretAccessKey" ]]; then
      # 定义环境变量
      export AWS_ACCESS_KEY_ID="$awsAccessKeyId"
      export AWS_SECRET_ACCESS_KEY="$awsSecretAccessKey"
    else
      echo "缺少awsAccessKeyId或secretAccessKey。正在退出。"
      exit 1
    fi

  elif [[ "${env}" == "sit" ]]; then
    ES_HOST="${SIT_ES_HOST}"
    ES_PORT="${SIT_ES_PORT}"
    ES_USERNAME="${SIT_ES_USERNAME}"
    ES_PASSWORD="${SIT_ES_PASSWORD}"
    ES_PROTOCOL="${SIT_ES_PROTOCOL}"
    KIBANA_URL="${SIT_KIBANA_URL}"
    KIBANA_INDEX_UUID="${SIT_KIBANA_INDEX_UUID}"
  else
    echo "未识别的运行环境：${env}" >&2
    exit 1
  fi
  echo "当前ES环境：${env}"
  echo "Host：${ES_HOST}"
  echo "Port：${ES_PORT}"
  echo "UserName：${ES_USERNAME}"
  echo "Password：${ES_PASSWORD}"
  echo "Protocol：${ES_PROTOCOL}"
  echo "Kibana_URL：${KIBANA_URL}"
}

# 清空旧的日志文件
clean_old_logs() {
  #clean old logs
  find ${logdir} -type f -name "aurora-*.log" -mtime +2 | xargs rm -f
  cd ${logdir} && rm aurora-*-mysql-*.log
}

# 同步aws数据库日志文件
sync_db_log_files() {
  local current_date=$(date +"%Y%m%d")  # 获取当前日期

  for db in ${databases_list[@]}; do
    # 获取循环库-每天慢查询文件名，最后一个
    #/usr/local/bin/aws rds describe-db-log-files --db-instance-identifier ${db} --output text | awk '{print $3}' | sed '$d' | grep "mysql-slowquery" | tail -1 >${db}.list

    # for slowfile_name in $( #将每个库-上一个小时生产的日志存放在本地日志中
    #   # cat ${db}.list
    # ); do
    #   slow_name=$(echo "${slowfile_name}" | awk -F '.' '{print $3"."$4}')
    #   /usr/local/bin/aws rds download-db-log-file-portion --db-instance-identifier ${db} --log-file-name ${slowfile_name} --starting-token 0 --output text >${logdir}/${db}-${slow_name}.log
    # done
    
    # 获取循环库-每天慢查询文件名(aws rds 只保存24小时以内日志,共有24个日志) 
    slowfile_names=$(/usr/local/bin/aws rds describe-db-log-files --db-instance-identifier ${db} --output text | awk '{print $3}' | grep "mysql-slowquery")

    for slowfile_name in $slowfile_names; do
      slow_name=$(echo "${slowfile_name}" | awk -F '.' '{print $3"."$4}')
      /usr/local/bin/aws rds download-db-log-file-portion --db-instance-identifier ${db} --log-file-name ${slowfile_name} --starting-token 0 --output text > ${logdir}/${db}-${slow_name}-${current_date}.log
    done

    # 合并当前数据库的日志文件
    cat ${logdir}/${db}-*-${current_date}.log > ${logdir}/${db}-slowquery_merged_logs-${current_date}.log
  done
}

# # 统计耗时最长的N条慢查询
# mysqldumpslow() {
#   cd ${logdir}

#   # 使用通配符找到所有满足模式的文件
#   for file in aurora-*-mysql-slowquery_merged_logs-*; do
#     # 获取最新的文件
#     latest_file=$(ls -l "$file" | tail -1 | awk '{print $NF}')

#     # 提取文件名中需要的部分
#     output_filename=$(echo "$latest_file" | cut -d '-' -f1-3)

#     # 对最新的文件执行mysqldumpslow命令，按查询时间排序，仅显示输出中的前 N ​​个查询。并将结果输出到一个新的日志文件中
#     /usr/bin/mysqldumpslow -s t -t "$log_num" "$latest_file" >"/usr/local/filebeat/logs/${output_filename}.log"

#     echo "统计近1天耗时最长的$log_num条慢查询日志文件: ${output_filename}.log"
#   done
# }


# 统计耗时最长的N条慢查询
mysqldumpslow() {
  cd ${logdir}

  # 使用通配符找到所有满足模式的文件
  for file in aurora-*-mysql-slowquery_merged_logs-*; do
    # 获取最新的文件
    latest_file=$(ls -l "$file" | tail -1 | awk '{print $NF}')

    # 提取文件名中需要的部分
    output_filename=$(echo "$latest_file" | cut -d '-' -f1-3)

    # 创建一个临时文件存储过滤后的慢查询日志
    filtered_slow_log="/usr/local/filebeat/logs/${output_filename}_filtered.log"

    # 创建一个文件存储被过滤掉的慢查询日志
    excluded_slow_log="/usr/local/filebeat/logs/${output_filename}_excluded.log"

    # 定义一个空字符串作为过滤模式
    filter_pattern=""

    # 检查并删除已存在的文件
    for logfile in "$filtered_slow_log" "$excluded_slow_log" "/usr/local/filebeat/logs/${output_filename}.log"
    do
      if [ -e "$logfile" ]; then
        rm "$logfile"
        echo "已删除旧日志文件：$logfile"
      fi
    done    

    # 循环生成过滤模式
    for user in "${user_array[@]}"
    do
      # 如果过滤模式不为空，则在前面添加"|"
      if [ -n "$filter_pattern" ]; then
        filter_pattern+="|"
      fi
      # 添加用户到过滤模式
      filter_pattern+="# User@Host: $user\\[$user\\]"
    done

    echo "过滤白名单用户：${user_array[@]}"

    # 使用awk过滤掉特定用户的所有查询，并将被过滤掉的查询保存到另一个文件
    awk -v pattern="$filter_pattern" '
    BEGIN { RS="# Time: "; ORS="" }
    $0 ~ pattern { print (NR==1 ? "" : "# Time: ") $0 >> "'$excluded_slow_log'" }
    $0 !~ pattern { print (NR==1 ? "" : "# Time: ") $0 }
    ' "$latest_file" > "$filtered_slow_log"

    echo "保存过滤后的慢查询日志文件：${filtered_slow_log}"
    echo "保存被过滤掉的慢查询日志文件：${excluded_slow_log}"

    # 对过滤后的慢查询日志进行分析
    /usr/bin/mysqldumpslow -s t -t "$log_num" "$filtered_slow_log" >"/usr/local/filebeat/logs/${output_filename}.log"

    echo "统计近1天耗时最长的$log_num条慢查询日志文件（已过滤白名单用户）: ${output_filename}.log"
  done
}


# 检查索引是否存在
check_index() {
  echo "check_index"
  response=$(curl -s -o /dev/null -w "%{http_code}" -u "${ES_USERNAME}:${ES_PASSWORD}" -X GET "${ES_PROTOCOL}://${ES_HOST}:${ES_PORT}/${ES_INDEX_NAME}-$(date +"%Y.%m.%d")")
  if [ "${response}" == "200" ]; then
    echo "索引 ${ES_INDEX_NAME} 存在."
  else
    echo "索引 ${ES_INDEX_NAME} 不存在。正在创建索引..."
    create_index
  fi
}

# 创建索引
create_index() {
  echo "create_index"
  INDEX_URL="${ES_PROTOCOL}://${ES_HOST}:${ES_PORT}/${ES_INDEX_NAME}-$(date +"%Y.%m.%d")"
  echo "URL: $INDEX_URL"
  curl -u "${ES_USERNAME}:${ES_PASSWORD}" -X PUT "$INDEX_URL" -H "Content-Type: application/json" -d '{
  "mappings": {
    "properties": {
      "DBInstance": {
        "type": "text"
      },
      "Count": {
        "type": "integer"
      },
      "Time": {
        "type": "double"
      },
      "Time_total": {
        "type": "double"
      },
      "Lock": {
        "type": "double"
      },
      "Lock_total": {
        "type": "double"
      },
      "Rows": {
        "type": "integer"
      },
      "Rows_total": {
        "type": "integer"
      },
      "UserHost": {
        "type": "text"
      },
      "SQL": {
        "type": "text"
      },
      "Username": {
        "type": "text"
      },
      "Host": {
        "type": "ip"
      },
      "Original_query": {
        "type": "text"
      },
      "Trace_id": {
        "type": "text"
      },
      "timestamp": {
        "type": "date",
        "format": "strict_date_optional_time||epoch_millis"
      }
    }
  }
}
'

  if [ $? -eq 0 ]; then
    echo "索引 ${ES_INDEX_NAME} 创建成功."
  else
    echo "创建索引失败 ${ES_INDEX_NAME}."
    # 退出
    echo "正在退出。"
    exit 1
  fi
}

# 写入数据到索引
write_to_index() {

  local DBInstance=$1
  local Count=$2
  local Time=$3
  local Time_total=$4
  local Lock=$5
  local Lock_total=$6
  local Rows=$7
  local Rows_total=$8
  local UserHost=$9
  local SQL=${10}
  local Username=${11}
  local Host=${12}
  local Original_query=${13}

  # 获取当前时间戳（ISO 8601格式）
  local TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # 将 SQL 转换为 JSON 格式
  local SQL_JSON=$(echo "$SQL" | jq -R .)

  # echo "请求参数： {
  #      \"DBInstance\": \"$DBInstance\",
  #      \"Count\": \"$Count\",
  #      \"Time\": \"$Time\",
  #      \"Time_total\": \"$Time_total\",
  #      \"Lock\": \"$Lock\",
  #      \"Lock_total\": \"$Lock_total\",
  #      \"Rows\": \"$Rows\",
  #      \"Rows_total\": \"$Rows_total\",
  #      \"UserHost\": \"$UserHost\",
  #      \"SQL\": $SQL_JSON,
  #      \"Username\": \"$Username\",
  #      \"Host\": \"$Host\",
  #      \"Original_query\":$Original_query,
  #      \"timestamp\": \"$TIMESTAMP\",
  #      \"Trace_id\": \"$Trace_id\"
  #     }"

  # 发送请求
  local RESPONSE=$(curl -u "${ES_USERNAME}:${ES_PASSWORD}" -X POST "${ES_PROTOCOL}://${ES_HOST}:${ES_PORT}/${ES_INDEX_NAME}-$(date +"%Y.%m.%d")/_doc" -H 'Content-Type: application/json' -d"
{
  \"DBInstance\": \"$DBInstance\",
  \"Count\": \"$Count\",
  \"Time\": \"$Time\",
  \"Time_total\": \"$Time_total\",
  \"Lock\": \"$Lock\",
  \"Lock_total\": \"$Lock_total\",
  \"Rows\": \"$Rows\",
  \"Rows_total\": \"$Rows_total\",
  \"UserHost\": \"$UserHost\",
  \"SQL\": $SQL_JSON,
  \"Username\": \"$Username\",
  \"Host\": \"$Host\",
  \"Original_query\":$Original_query,
  \"timestamp\": \"$TIMESTAMP\",
  \"Trace_id\": \"$Trace_id\"
}")

  echo "Response: $RESPONSE"
}

# 发送钉钉消息
send_dingding_message() {
  local DBInstance=$1
  local Host=$2
  local TraceId=$3
  local AccessToken=$4

  # 获取当前时间（北京时间，用于显示和日志）
  display_time=$(TZ='Asia/Shanghai' date +"%Y-%m-%d %H:%M:%S")

  # url=${KIBANA_URL}+"#/?_g=(filters:!(),refreshInterval:(pause:!t,value:0),time:(from:now-1d,to:now))&_a=(columns:!(),filters:!(),index:'${KIBANA_INDEX_UUID}',interval:auto,query:(language:kuery,query:\"${DBInstance}\"),sort:!(!(timestamp,desc)))"
  url="${KIBANA_URL}#/?_g=(filters:!(),refreshInterval:(pause:!t,value:0),time:(from:now-1d,to:now))&_a=(columns:!(),filters:!(),index:'${KIBANA_INDEX_UUID}',interval:auto,query:(language:kuery,query:\\\"${DBInstance}\\\"),sort:!(!(timestamp,desc)))"

  data='{
    "msgtype": "markdown",
    "markdown": {
      "title": "'"${DBInstance}"' 【统计近1天耗时最长的'"$log_num"'条慢查询】",
      "text": "# <font color=\"red\">'"${DBInstance}"' 【统计近1天耗时最长的'"$log_num"'条慢查询】</font>\n- **告警环境**: '"${env}"'\n- **告警实例**: '"${DBInstance}"'\n- **告警时间**: '"${display_time}"'\n- **告警索引**: '"${ES_INDEX_NAME}"-$(date +"%Y.%m.%d")'\n- **TraceId**: '"${TraceId}"'\n- **详情请戳**: [Kinban搜索TraceId]('"${url}"')"
    },
    "at": {
      "isAtAll": true
    }
  }'

  echo "send_dingding_message: $data"
  local dingtalk_url="$webhook_url$AccessToken"
  curl "$dingtalk_url" -H 'Content-Type: application/json' -d "$data"
}

# 主逻辑
main() {
  # 检查必填参数
  check_required_params

  # 检查环境
  check_env

  if [[ "${env}" == "prod" ]]; then
    # 清空旧的日志文件
    clean_old_logs

    # 同步aws数据库日志文件
    sync_db_log_files
  else
    echo "跳过日志清空和数据库日志文件同步，运行环境：${env}"
  fi

  # 运行慢查询日志统计
  mysqldumpslow

  # 检查索引是否存在
  check_index

  # 指定要扫描的目录和文件模式
  pattern="aurora-*-mysql.log"

  # 找到所有匹配的文件
  files=$(find "$logdir" -name "$pattern")

  # 遍历每个文件
  for file in $files; do
    # 从文件名中解析出数据库实例名称
    filename=$(basename "$file")
    DBInstance=$(echo "$filename" | cut -d '.' -f1)

    # 初始化变量
    Count=""
    Time=""
    Time_total=""
    Lock=""
    Lock_total=""
    Rows=""
    Rows_total=""
    UserHost=""
    SQL=""
    Username=""
    Host=""
    Original_query=""
    Trace_id=$(date +"%Y%m%d%H%M%S")

    # 从文件中读取行
    while IFS= read -r line; do
      if [[ $line == "Count:"* ]]; then
        # 当遇到新的查询块时，发送已解析的查询
        if [ ! -z "$SQL" ]; then

          SQL_JSON=$(echo "$SQL" | jq -R .)
          Original_query_JSON=$(echo "$Original_query" | jq -R .)
          # 写入数据到索引
          write_to_index "$DBInstance" "$Count" "$Time" "$Time_total" "$Lock" "$Lock_total" "$Rows" "$Rows_total" "$UserHost" "$SQL" "$Username" "$Host" "$Original_query_JSON" "$Trace_id"
        fi

        # 提取统计信息
        Count=$(echo "$line" | perl -n -e'/Count: (\d+)/ && print $1')              # 慢sql的出现次数(Count) （慢查询日志中出现的次数）
        Time=$(echo "$line" | perl -n -e'/Time=(.*?)s/ && print $1')                # 执行最长时间(Time)
        Time_total=$(echo "$line" | perl -n -e'/Time=.*?s \((.*?)s\)/ && print $1') # 累计总耗费时间(Time)
        Lock=$(echo "$line" | perl -n -e'/Lock=(.*?)s/ && print $1')                # 锁定时间(Lock)
        Lock_total=$(echo "$line" | perl -n -e'/Lock=.*?s \((.*?)s\)/ && print $1') # 累计锁定时间(Time)
        Rows=$(echo "$line" | perl -n -e'/Rows=(.*?) / && print $1')                # 发送给客户端的行总数(Rows)
        Rows_total=$(echo "$line" | perl -n -e'/Rows=.*? \((.*?)\)/ && print $1')   # 累计扫描的行总数(Rows)
        UserHost=$(echo "$line" | awk -F',' '{print $2}' | sed 's/^ *//')           # 用户主机
        Username=$(echo "$UserHost" | perl -n -e'/(\w+)\[.*?\]/ && print $1')       # 用户名
        # 提取客户端 IP 地址，如果为空则使用默认值
        Host=$(echo "$UserHost" | perl -n -e'/@\[(.*)\]/ && print $1')
        if [ -z "$Host" ]; then
            Host="127.0.0.1"  # 默认 IP 地址，您可以根据实际情况修改
        fi
        
        # 重置 SQL 和 Original_query 变量
        SQL=""
        Original_query="$line"
      else
        # 累积 SQL 查询和原始查询
        SQL+="$line"
        Original_query+="$line"
      fi
    done <"$file"

    # 发送最后一个查询
    if [ ! -z "$SQL" ]; then

      SQL_JSON=$(echo "$SQL" | jq -R .)
      Original_query_JSON=$(echo "$Original_query" | jq -R .)
      # 写入数据到索引
      write_to_index "$DBInstance" "$Count" "$Time" "$Time_total" "$Lock" "$Lock_total" "$Rows" "$Rows_total" "$UserHost" "$SQL" "$Username" "$Host" "$Original_query_JSON" "$Trace_id"
    fi

    # 当文件处理完毕，如果当前北京时间是上午10:00到10:59，则发送钉钉消息
    current_time=$(TZ=":Asia/Shanghai" date +"%H%M")
    if (((current_time >= 1000 && current_time < 1059))); then
      # 应用负责人群
      send_dingding_message "$DBInstance" "$Host" "$Trace_id" "$access_token"
      # 产研中心群
      send_dingding_message "$DBInstance" "$Host" "$Trace_id" "$access_token_team"
    else
      echo "禁止推送钉钉消息"
    fi
  done
}

# 执行主逻辑
main
