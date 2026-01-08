#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
ENV_FILE="${SCRIPT_DIR}/../.env"
OCI_CONFIG_FILE="${SCRIPT_DIR}/../.oci/config"
OCI_KEY_FILE="${SCRIPT_DIR}/../.oci/key.pem"

if [[ -f "$ENV_FILE" ]]; then
  # Load environment variables from the .env file.
  # shellcheck source=/dev/null
  source "$ENV_FILE"
else
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

if [[ -f "$OCI_KEY_FILE" ]]; then
  export OCI_CLI_KEY_FILE="$OCI_KEY_FILE"
else
  echo "Missing OCI key file: $OCI_KEY_FILE" >&2
  exit 1
fi

COMPARTMENT_OCID="${COMPARTMENT_ID:-}"

if [[ -z "$COMPARTMENT_OCID" ]]; then
  echo "COMPARTMENT_ID is not set in $ENV_FILE" >&2
  exit 1
fi

list_instances() {
  local raw_instances
  raw_instances="$(oci --config-file "$OCI_CONFIG_FILE" compute instance list --compartment-id "$COMPARTMENT_OCID" --all --output json)"
  local raw_file="/tmp/log.ociinstance.tmp"
  printf '%s' "$raw_instances" > "$raw_file"

  # Collect boot-volume attachments across all availability domains used by nf-runner instances.
  local attachments_file="/tmp/log.ociinstance.attachments.tmp"
  printf '%s' '[]' > "$attachments_file"
  local resp_file="/tmp/log.ociinstance.resp.tmp"
  local merge_file="/tmp/log.ociinstance.merge.tmp"

  mapfile -t ads < <(echo "$raw_instances" | jq -r '.data[]? | select((."display-name" // "" | tostring | startswith("nf-runner"))) | ."availability-domain"' | sort -u)
  for ad in "${ads[@]}"; do
    if [[ -n "$ad" ]]; then
      resp="$(oci --config-file "$OCI_CONFIG_FILE" compute boot-volume-attachment list --compartment-id "$COMPARTMENT_OCID" --availability-domain "$ad" --all --output json 2>/dev/null || echo "{}")"
      printf '%s' "$resp" > "$resp_file"
      jq -s '
        def as_array:
          if type == "array" then .
          else []
          end;
        (if type == "array" then . else [.] end) as $inputs
        | ($inputs[0] | as_array) + ($inputs[1] | .data? // [] | as_array)
      ' "$attachments_file" "$resp_file" > "$merge_file"
      mv "$merge_file" "$attachments_file"
    fi
  done

  jq -s '
    def as_array:
      if type == "array" then .
      else []
      end;

    def data_array:
      if type == "object" and has("data") then .data
      elif type == "array" then .
      else []
      end;

    def boot_size_for($inputs; id):
      ($inputs[1] | as_array)
      | map(select(.["instance-id"] == id or .instanceId == id))
      | map(.["boot-volume-size-in-gbs"] // .bootVolumeSizeInGBs)
      | first // null;

    def boot_volume_id_for($inputs; id):
      ($inputs[1] | as_array)
      | map(select(.["instance-id"] == id or .instanceId == id))
      | map(.["boot-volume-id"] // .bootVolumeId)
      | map(select(. != null))
      | first // null;

    (if type == "array" then . else [.] end) as $inputs
    | ($inputs[0] | data_array)
    | map(
        select(
          (.["display-name"] // "" | tostring | startswith("nf-runner")) and
          ((.["lifecycle-state"] as $state | ["PROVISIONING","RUNNING","TERMINATING","STOPPING","STOPPED"] | index($state)) != null)
        )
      )
    | sort_by(."display-name")
    | map({
        id: .id,
        name: ."display-name",
        state: ."lifecycle-state",
        shape: .shape,
        cpu: ."shape-config".ocpus,
        mem: ."shape-config"."memory-in-gbs",
        gpu: (
          ."shape-config".gpus
          // ."shape-config"."gpu"
          // .["shape-config"]["gpu-count"]
          // .["shape-config"]["gpuCount"]
          // null
        ),
        created: (
          .["time-created"]
          // .["timeCreated"]
          // .["time_created"]
          // null
        ),
        disk: (
          boot_size_for($inputs; .id)
          // .["sourceDetails"]["bootVolumeSizeInGBs"]
          // .["source-details"]["boot-volume-size-in-gbs"]
          // ."shape-config"."local-disk-total-size-in-gbs"
          // .["shape-config"]["localDiskTotalSizeInGBs"]
          // .["shape-config"]["local-disk-size-in-gbs"]
          // .["shape-config"]["boot-volume-size-in-gbs"]
          // null
        ),
        boot_id: (
          boot_volume_id_for($inputs; .id)
        ),
        net_gbps: (
          ."shape-config"."networking-bandwidth-in-gbps"
          // .["shape-config"]["networkingBandwidthInGbps"]
          // .["shape-config"]["max-networking-bandwidth-in-gbps"]
          // null
        )
      })
  ' "$raw_file" "$attachments_file"
}

print_table() {
  local json="$1"
  local now_epoch
  now_epoch="$(date +%s)"
  local net_window_minutes
  net_window_minutes="${NET_WINDOW_MINUTES:-1}"
  local net_interval
  net_interval="${NET_METRIC_INTERVAL:-1m}"
  local net_namespace
  net_namespace="${NET_METRIC_NAMESPACE:-oci_computeagent}"
  local disk_window_minutes
  disk_window_minutes="${DISK_WINDOW_MINUTES:-1}"
  local disk_interval
  disk_interval="${DISK_METRIC_INTERVAL:-$net_interval}"
  local disk_namespace
  disk_namespace="${DISK_METRIC_NAMESPACE:-oci_blockstorage}"
  local metric_lag_minutes
  metric_lag_minutes="${METRIC_LAG_MINUTES:-2}"
  local end_time net_start_time disk_start_time
  end_time="$(date -u -d "-${metric_lag_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ")"
  net_start_time="$(date -u -d "-$((metric_lag_minutes + net_window_minutes)) minutes" +"%Y-%m-%dT%H:%M:%SZ")"
  disk_start_time="$(date -u -d "-$((metric_lag_minutes + disk_window_minutes)) minutes" +"%Y-%m-%dT%H:%M:%SZ")"

  interval_to_seconds() {
    local value="$1"
    if [[ "$value" =~ ^([0-9]+)s$ ]]; then
      echo "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([0-9]+)m$ ]]; then
      echo "$((BASH_REMATCH[1] * 60))"
    elif [[ "$value" =~ ^([0-9]+)h$ ]]; then
      echo "$((BASH_REMATCH[1] * 3600))"
    else
      echo "60"
    fi
  }
  local disk_interval_seconds
  disk_interval_seconds="$(interval_to_seconds "$disk_interval")"

  local totals
  totals="$(echo "$json" | jq -r '
    def to_num: (. // 0 | tonumber? // 0);
    [
      (map(.cpu | to_num) | add // 0),
      (map(.mem | to_num) | add // 0),
      (map(.gpu | to_num) | add // 0)
    ] | @tsv
  ')"

  format_uptime() {
    local created="$1"
    local now="$2"
    if [[ -z "$created" ]]; then
      echo ""
      return
    fi
    local ts="${created/Z/+00:00}"
    ts="$(echo "$ts" | sed -E 's/\\.[0-9]+//')"
    local epoch
    epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
    if [[ -z "$epoch" ]]; then
      local ts2
      ts2="$(echo "$ts" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\\1\\2/')"
      epoch="$(date -d "$ts2" +%s 2>/dev/null || true)"
    fi
    if [[ -z "$epoch" ]]; then
      echo ""
      return
    fi
    local diff=$((now - epoch))
    if (( diff < 0 )); then
      diff=0
    fi
    local days=$((diff / 86400))
    local hours=$(((diff % 86400) / 3600))
    local mins=$(((diff % 3600) / 60))
    local out=""
    if (( days > 0 )); then
      out+="${days}d"
    fi
    if (( hours > 0 || days > 0 )); then
      out+="${hours}h"
    fi
    out+="${mins}m"
    echo "$out"
  }

  query_metric_mean() {
    local metric="$1"
    local instance_id="$2"
    local query="${metric}[${net_interval}]{resourceId = \"${instance_id}\"}.mean()"
    local resp
    resp="$(oci --config-file "$OCI_CONFIG_FILE" monitoring metric-data summarize \
      --compartment-id "$COMPARTMENT_OCID" \
      --namespace "$net_namespace" \
      --query-text "$query" \
      --start-time "$net_start_time" \
      --end-time "$end_time" \
      --output json 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
      echo ""
      return
    fi
    local value
    value="$(echo "$resp" | jq -r '[.data[]? | (.["aggregated-datapoints"] // .aggregatedDatapoints // [])[]? | .value] | if length==0 then "" else (add/length) end')"
    if [[ "$value" == "null" ]]; then
      value=""
    fi
    echo "$value"
  }

  net_gbps_for_instance() {
    local instance_id="$1"
    local in_val out_val
    in_val="$(query_metric_mean "NetworkBytesIn" "$instance_id")"
    out_val="$(query_metric_mean "NetworkBytesOut" "$instance_id")"
    if [[ -z "$in_val" && -z "$out_val" ]]; then
      in_val="$(query_metric_mean "VnicNetworkBytesIn" "$instance_id")"
      out_val="$(query_metric_mean "VnicNetworkBytesOut" "$instance_id")"
    fi
    if [[ -z "$in_val" && -z "$out_val" ]]; then
      echo ""
      return
    fi
    if [[ -z "$in_val" ]]; then
      in_val="0"
    fi
    if [[ -z "$out_val" ]]; then
      out_val="0"
    fi
    awk -v a="$in_val" -v b="$out_val" 'BEGIN{printf "%.3f", ((a+b)*8)/1000000000}'
  }

  private_ip_for_instance() {
    local instance_id="$1"
    local resp
    resp="$(oci --config-file "$OCI_CONFIG_FILE" compute instance list-vnics \
      --instance-id "$instance_id" \
      --all \
      --output json 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
      echo ""
      return
    fi
    local ip
    ip="$(echo "$resp" | jq -r '
      def ipval: .["private-ip"] // .privateIp // "";
      (.data // []) as $vnics
      | ($vnics | map(select((.["is-primary"] // .isPrimary // false) == true)) | first) as $primary
      | if $primary != null then ($primary | ipval)
        elif ($vnics | length) > 0 then ($vnics[0] | ipval)
        else ""
        end
    ')"
    if [[ "$ip" == "null" ]]; then
      ip=""
    fi
    echo "$ip"
  }

  query_disk_metric_mean() {
    local metric="$1"
    local volume_id="$2"
    local query="${metric}[${disk_interval}]{resourceId = \"${volume_id}\"}.mean()"
    local resp
    resp="$(oci --config-file "$OCI_CONFIG_FILE" monitoring metric-data summarize \
      --compartment-id "$COMPARTMENT_OCID" \
      --namespace "$disk_namespace" \
      --query-text "$query" \
      --start-time "$disk_start_time" \
      --end-time "$end_time" \
      --output json 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
      echo ""
      return
    fi
    local value
    value="$(echo "$resp" | jq -r '[.data[]? | (.["aggregated-datapoints"] // .aggregatedDatapoints // [])[]? | .value] | if length==0 then "" else (add/length) end')"
    if [[ "$value" == "null" ]]; then
      value=""
    fi
    if [[ -n "$value" ]]; then
      echo "$value"
      return
    fi
    query="${metric}[${disk_interval}]{volumeId = \"${volume_id}\"}.mean()"
    resp="$(oci --config-file "$OCI_CONFIG_FILE" monitoring metric-data summarize \
      --compartment-id "$COMPARTMENT_OCID" \
      --namespace "$disk_namespace" \
      --query-text "$query" \
      --start-time "$disk_start_time" \
      --end-time "$end_time" \
      --output json 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
      echo ""
      return
    fi
    value="$(echo "$resp" | jq -r '[.data[]? | (.["aggregated-datapoints"] // .aggregatedDatapoints // [])[]? | .value] | if length==0 then "" else (add/length) end')"
    if [[ "$value" == "null" ]]; then
      value=""
    fi
    echo "$value"
  }

  disk_mb_s_for_volume() {
    local volume_id="$1"
    if [[ -z "$volume_id" ]]; then
      echo ""
      return
    fi
    local read_val write_val divisor
    divisor=1
    read_val="$(query_disk_metric_mean "ReadThroughput" "$volume_id")"
    write_val="$(query_disk_metric_mean "WriteThroughput" "$volume_id")"
    if [[ -z "$read_val" && -z "$write_val" ]]; then
      read_val="$(query_disk_metric_mean "ReadBytes" "$volume_id")"
      write_val="$(query_disk_metric_mean "WriteBytes" "$volume_id")"
      divisor="$disk_interval_seconds"
    fi
    if [[ -z "$read_val" && -z "$write_val" ]]; then
      echo ""
      return
    fi
    if [[ -z "$read_val" ]]; then
      read_val="0"
    fi
    if [[ -z "$write_val" ]]; then
      write_val="0"
    fi
    awk -v a="$read_val" -v b="$write_val" -v d="$divisor" 'BEGIN{printf "%.3f", ((a+b)/d)/1000000}'
  }

  {
    printf "%s\n" "index	name	shape	state	private_ip	cpu	mem	gpu	net_gbps	disk_MBps	uptime"
    local idx=0
    local total_net="0"
    local net_total_set=0
    local total_disk="0"
    local disk_total_set=0
    while IFS=$'\t' read -r id name shape state cpu mem gpu created boot_id; do
      idx=$((idx + 1))
      local uptime
      uptime="$(format_uptime "$created" "$now_epoch")"
      local private_ip
      private_ip="$(private_ip_for_instance "$id")"
      if [[ -z "$private_ip" ]]; then
        private_ip="-"
      fi
      local net_gbps
      net_gbps="$(net_gbps_for_instance "$id")"
      if [[ -n "$net_gbps" ]]; then
        total_net="$(awk -v a="$total_net" -v b="$net_gbps" 'BEGIN{printf "%.3f", a+b}')"
        net_total_set=1
      else
        net_gbps="-"
      fi
      local disk_mb_s
      disk_mb_s="$(disk_mb_s_for_volume "$boot_id")"
      if [[ -n "$disk_mb_s" ]]; then
        total_disk="$(awk -v a="$total_disk" -v b="$disk_mb_s" 'BEGIN{printf "%.3f", a+b}')"
        disk_total_set=1
      else
        disk_mb_s="-"
      fi
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$idx" "$name" "$shape" "$state" "$private_ip" "$cpu" "$mem" "$gpu" "${net_gbps:-}" "${disk_mb_s:-}" "$uptime"
    done < <(echo "$json" | jq -r '.[] | [.id, .name, .shape, .state, (.cpu // ""), (.mem // ""), (.gpu // ""), (.created // ""), (.boot_id // "")] | @tsv')

    local total_cpu total_mem total_gpu
    IFS=$'\t' read -r total_cpu total_mem total_gpu <<< "$totals"
    local total_net_display="-"
    if [[ "$net_total_set" -eq 1 ]]; then
      total_net_display="$total_net"
    fi
    local total_disk_display="-"
    if [[ "$disk_total_set" -eq 1 ]]; then
      total_disk_display="$total_disk"
    fi
    printf "%s\n" "-	TOTAL	-	-	-	${total_cpu}	${total_mem}	${total_gpu}	${total_net_display}	${total_disk_display}	-"
  } | column -t
}

terminate_instances() {
  local json="$1"
  local ids=()
  mapfile -t ids < <(echo "$json" | jq -r '.[].id')

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No nf-runner instances found to terminate."
    return 0
  fi

  print_table "$json"
  echo "Terminating ${#ids[@]} instance(s) in 5 seconds... (Ctrl+C to cancel)"
  sleep 5

  for id in "${ids[@]}"; do
    echo "Terminating $id"
    oci --config-file "$OCI_CONFIG_FILE" compute instance terminate --instance-id "$id" --force >/dev/null
  done
}

command="${1:-}"

instances_json="$(list_instances)"

case "$command" in
  display)
    print_table "$instances_json"
    ;;
  kill)
    terminate_instances "$instances_json"
    ;;
  *)
    print_table "$instances_json"
    ;;
esac
