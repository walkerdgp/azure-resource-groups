#!/bin/bash
# =============================================================================
# azure_resource_info.sh — Inventário para recursos sem métricas
# /usr/lib/zabbix/externalscripts/azure_resource_info.sh
#
# Uso: azure_resource_info.sh <RESOURCE_ID> <TYPE>
# =============================================================================

CONF="/etc/zabbix/azure.conf"
[[ -f "$CONF" ]] && source "$CONF"

RESOURCE_ID="$1"; RTYPE="${2:-unknown}"
die() { echo "{\"status\":\"error\",\"error\":\"$*\",\"_type\":\"$RTYPE\"}"; exit 1; }
[[ -z "$RESOURCE_ID" ]] && die "RESOURCE_ID vazio"

export AZURE_CONFIG_DIR="/var/lib/zabbix/.azure"
az account show --query "id" -o tsv 2>/dev/null | grep -q . || {
    (
        flock -w 30 200 || die "timeout lock"
        az account show --query "id" -o tsv 2>/dev/null | grep -q . && exit 0
        az login --service-principal \
            -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" \
            --tenant "$AZURE_TENANT_ID" -o none 2>/dev/null || die "az login falhou"
        az account set --subscription "$AZURE_SUBSCRIPTION_ID" -o none 2>/dev/null
    ) 200>/tmp/.zabbix_azure.lock
}

RAW=$(az resource show --ids "$RESOURCE_ID" \
    --query "{name:name,type:type,location:location,tags:tags,state:properties.provisioningState}" \
    -o json 2>/dev/null)

[[ -z "$RAW" ]] && die "Recurso nao encontrado"

python3 -c "
import json, datetime
d = json.loads(r'''$RAW''')
d['status'] = 'ok'; d['_type'] = '$RTYPE'
d['_collected_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(d))
" 2>/dev/null || die "parse failed"
