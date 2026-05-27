#!/bin/bash
# =============================================================================
# azure_get_metrics.sh — Coleta batch de métricas Azure para Zabbix 7.0 LTS
# /usr/lib/zabbix/externalscripts/azure_get_metrics.sh
#
# Uso: azure_get_metrics.sh <RESOURCE_ID> <TYPE_LLD> <INTERVAL_MIN> <TYPE_FIXED>
# Subscription é extraída automaticamente do RESOURCE_ID.
# =============================================================================

CONF="/etc/zabbix/azure.conf"
[[ -f "$CONF" ]] && source "$CONF"

RESOURCE_ID="$1"
TYPE_LLD="$2"
INTERVAL="${3:-5}"
TYPE="${4:-$2}"

die() { echo "{\"status\":\"error\",\"error\":\"$*\"}"; exit 1; }

[[ -z "$RESOURCE_ID" ]] && die "RESOURCE_ID vazio"
[[ -z "$TYPE" ]]        && die "TYPE vazio"

# ── Extrair subscription do resource ID ──────────────────────────────────────
# Formato: /subscriptions/<SUB>/resourceGroups/<RG>/providers/...
SUB_FROM_ID=$(echo "$RESOURCE_ID" | sed 's|/subscriptions/||' | cut -d'/' -f1)
[[ -n "$SUB_FROM_ID" ]] && AZURE_SUBSCRIPTION_ID="$SUB_FROM_ID"

# ── Auth na subscription correta ─────────────────────────────────────────────
export AZURE_CONFIG_DIR="/var/lib/zabbix/.azure"
mkdir -p "$AZURE_CONFIG_DIR"

_auth() {
    local cur_sub
    cur_sub=$(az account show --query "id" -o tsv 2>/dev/null)
    [[ "$cur_sub" == "$AZURE_SUBSCRIPTION_ID" ]] && return 0
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" -o none 2>/dev/null && return 0
    (
        flock -w 30 200 || exit 1
        az account show --query "id" -o tsv 2>/dev/null | grep -q "$AZURE_SUBSCRIPTION_ID" && exit 0
        az login --service-principal \
            -u "$AZURE_CLIENT_ID" \
            -p "$AZURE_CLIENT_SECRET" \
            --tenant "$AZURE_TENANT_ID" \
            -o none 2>/dev/null || exit 1
        az account set --subscription "$AZURE_SUBSCRIPTION_ID" -o none 2>/dev/null
    ) 200>/tmp/.zabbix_azure.lock
}

_auth || die "Falha na auth para sub $AZURE_SUBSCRIPTION_ID"

# ── Métricas por tipo ─────────────────────────────────────────────────────────
declare -A M
M[vm]="Percentage CPU Available Memory Bytes Network In Total Network Out Total Disk Read Bytes Disk Write Bytes Disk Read Operations/Sec Disk Write Operations/Sec OS Disk IOPS Consumed Percentage OS Disk Read Bytes/sec OS Disk Write Bytes/sec OS Disk Queue Depth Inbound Flows Outbound Flows VM Availability Metric"
M[vmss]="Percentage CPU Available Memory Bytes Network In Total Network Out Total Disk Read Bytes Disk Write Bytes OS Disk IOPS Consumed Percentage Inbound Flows Outbound Flows"
M[web]="CpuTime Requests BytesReceived BytesSent Http2xx Http3xx Http4xx Http5xx Http401 Http403 Http404 MemoryWorkingSet AverageResponseTime AppConnections Handles Threads IoReadBytesPerSecond IoWriteBytesPerSecond PrivateBytes"
M[asp]="CpuPercentage MemoryPercentage DiskQueueLength HttpQueueLength BytesReceived BytesSent TcpSynSent TcpEstablished TcpTimeWait"
M[acr]="StorageUsed SuccessfulPushCount FailedPushCount SuccessfulPullCount FailedPullCount AgentPoolCPUTime RunDuration"
M[acr_rep]="AgentPoolCPUTime RunDuration"
M[containerapp]="Requests RequestsInProgress RestartCount ReplicaRunning ReplicaCount Latency ConnectionErrors NetworkInbound NetworkOutbound CpuUsageNanoCores MemoryWorkingSetBytes"
M[containerappsenv]="UsedCoreQuotaPercentage UsedMemoryQuotaPercentage NodeCount ActiveRevisionCount ContainerAppCount"
M[containerjob]="ExecutionCount SuccessfulExecutionCount FailedExecutionCount RunningExecutionCount StartedExecutionCount RestartCount"
M[sql]="cpu_percent dtu_consumption_percent storage_percent connection_successful connection_failed blocked_by_firewall deadlock workers_percent sessions_percent physical_data_read_percent log_write_percent tempdb_log_used_percent xtp_storage_percent"
M[pgsql]="cpu_percent memory_percent iops storage_percent storage_used active_connections connections_failed connections_succeeded network_bytes_ingress network_bytes_egress replication_lag deadlocks read_iops write_iops disk_bandwidth_consumed_percentage disk_iops_consumed_percentage maximum_used_transactionIDs"
M[cosmos]="TotalRequests TotalRequestUnits NormalizedRUConsumption DataUsage IndexUsage DocumentCount ServerSideLatency ServiceAvailability"
M[redis]="connectedclients totalcommandsprocessed cachehits cachemisses cachemissrate cacheRead cacheWrite percentProcessorTime serverLoad usedmemory usedmemorypercentage evictedkeys expiredkeys"
M[sb]="ActiveMessages DeadletteredMessages IncomingMessages OutgoingMessages ScheduledMessages ThrottledRequests ServerErrors UserErrors Size TransferMessages"
M[eh]="IncomingMessages OutgoingMessages IncomingBytes OutgoingBytes ActiveConnections CaptureBacklog CapturedMessages ThrottledRequests ServerErrors"
M[apim]="TotalRequests SuccessfulRequests UnauthorizedRequests FailedRequests OtherRequests Capacity Duration BackendDuration ClientDuration GatewayRequests NetworkConnectivity EventHubTotalEvents EventHubDroppedEvents"
M[law]="Heartbeat Average_% Processor Time Average_% Used Memory Average_% Free Space Average_Disk Reads/sec Average_Disk Writes/sec"
M[kv]="ServiceApiHit ServiceApiLatency ServiceApiResult SaturationShoebox Availability"
M[lb]="ByteCount PacketCount SYNCount SnatConnectionCount AllocatedSnatPorts UsedSnatPorts HealthProbeStatus DipAvailability VipAvailability"
M[appgw]="TotalRequests FailedRequests HealthyHostCount UnhealthyHostCount Throughput BytesReceived BytesSent CpuUtilization CurrentConnections NewConnectionsPerSecond ApplicationGatewayTotalTime BackendFirstByteResponseTime CapacityUnits BlockedCount"
M[pip]="ByteCount PacketCount SynCount IfUnderDDoSAttack DDoSTriggerTCPPackets DDoSTriggerUDPPackets VipAvailability"
M[pe]="PEBytesIn PEBytesOut"
M[nic]="BytesSentRate BytesReceivedRate PacketsSentRate PacketsReceivedRate"
M[storage]="UsedCapacity Transactions Ingress Egress SuccessServerLatency SuccessE2ELatency Availability"
M[aks]="node_cpu_usage_percentage node_memory_working_set_percentage node_disk_usage_percentage node_network_in_bytes node_network_out_bytes kube_pod_status_ready kube_node_status_condition kube_pod_status_phase"
M[nsg]=""; M[identity]=""; M[rt]=""

METRICS="${M[$TYPE]}"
if [[ -z "$METRICS" ]]; then
    echo "{\"status\":\"ok\",\"_type\":\"$TYPE\",\"_note\":\"inventory_only\"}"; exit 0
fi

END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START=$(date -u -d "-${INTERVAL} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
     || date -u -v-${INTERVAL}M +"%Y-%m-%dT%H:%M:%SZ")

RESULT="{}"; chunk=()

flush() {
    [[ ${#chunk[@]} -eq 0 ]] && return
    local RAW
    RAW=$(az monitor metrics list \
        --resource "$RESOURCE_ID" \
        --metrics ${chunk[*]} \
        --start-time "$START" --end-time "$END" \
        --interval "PT${INTERVAL}M" \
        --aggregation Average Total Maximum \
        -o json 2>/dev/null)
    if [[ $? -eq 0 && -n "$RAW" ]]; then
        PARTIAL=$(python3 -c "
import json
try:
    d=json.loads(r'''${RAW}'''); r={}
    for item in d.get('value',[]):
        name=item.get('name',{}).get('value','')
        for pt in reversed((item.get('timeseries') or [{}])[0].get('data',[])):
            v=pt.get('average') if pt.get('average') is not None else pt.get('total') if pt.get('total') is not None else pt.get('maximum')
            if v is not None: r[name]=v; break
    print(json.dumps(r))
except: print('{}')
" 2>/dev/null)
        RESULT=$(python3 -c "
import json
a=json.loads('$RESULT'); b=json.loads('$PARTIAL')
a.update(b); print(json.dumps(a))
" 2>/dev/null || echo "$RESULT")
    fi
    chunk=()
}

read -ra MARR <<< "$METRICS"
for m in "${MARR[@]}"; do
    [[ -z "$m" ]] && continue
    chunk+=("$m")
    [[ ${#chunk[@]} -ge 20 ]] && flush
done
flush

python3 -c "
import json,datetime
d=json.loads('$RESULT')
d['status']='ok' if d else 'no_data'
d['_type']='$TYPE'; d['_sub']='$AZURE_SUBSCRIPTION_ID'
d['_metric_count']=len([k for k in d if not k.startswith('_') and k!='status'])
d['_collected_at']=datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(d))
" 2>/dev/null || die "parse failed"
