#!/bin/bash
# =============================================================================
# azure_discovery.sh — LLD Discovery para Zabbix 7.0 LTS
# /usr/lib/zabbix/externalscripts/azure_discovery.sh
#
# Uso: azure_discovery.sh <TYPE> <RG> <SUB_ID> [TAG_INC_NAME] [TAG_INC_VALUE] [TAG_EXC_NAME] [TAG_EXC_VALUE]
# =============================================================================

CONF="/etc/zabbix/azure.conf"
[[ -f "$CONF" ]] && source "$CONF"

TYPE="$1"; RG="$2"; SUB_ID="$3"
TAG_INC_NAME="${4}"; TAG_INC_VALUE="${5:-true}"
TAG_EXC_NAME="${6}"; TAG_EXC_VALUE="${7:-true}"
TAG_APP_NAME="${8:-application}"  # Tag que contém o nome da aplicação

# SUB_ID do parâmetro tem prioridade sobre azure.conf
[[ -n "$SUB_ID" ]] && AZURE_SUBSCRIPTION_ID="$SUB_ID"

die() { echo '{"data":[]}'; echo "ERRO: $*" >&2; exit 1; }

[[ -z "$RG" ]]                   && die "Resource Group nao informado"
[[ -z "$AZURE_SUBSCRIPTION_ID" ]] && die "Subscription ID nao informado"

# ── Auth ──────────────────────────────────────────────────────────────────────
export AZURE_CONFIG_DIR="/var/lib/zabbix/.azure"
mkdir -p "$AZURE_CONFIG_DIR"

_auth() {
    local cur_sub
    cur_sub=$(az account show --query "id" -o tsv 2>/dev/null)
    if [[ "$cur_sub" == "$AZURE_SUBSCRIPTION_ID" ]]; then
        return 0
    fi
    if az account set --subscription "$AZURE_SUBSCRIPTION_ID" -o none 2>/dev/null; then
        return 0
    fi
    (
        flock -w 30 200 || die "timeout lock auth"
        az account show --query "id" -o tsv 2>/dev/null | grep -q "$AZURE_SUBSCRIPTION_ID" && exit 0
        az login --service-principal \
            -u "$AZURE_CLIENT_ID" \
            -p "$AZURE_CLIENT_SECRET" \
            --tenant "$AZURE_TENANT_ID" \
            -o none 2>/dev/null || exit 1
        az account set --subscription "$AZURE_SUBSCRIPTION_ID" -o none 2>/dev/null
    ) 200>/tmp/.zabbix_azure.lock
}

_auth || die "Falha na autenticacao para subscription $AZURE_SUBSCRIPTION_ID"

# ── Mapa tipo → azure_type ────────────────────────────────────────────────────
declare -A TMAP=(
    [vm]="microsoft.compute/virtualmachines"
    [vmss]="microsoft.compute/virtualmachinescalesets"
    [web]="microsoft.web/sites"
    [asp]="microsoft.web/serverfarms"
    [acr]="microsoft.containerregistry/registries"
    [acr_rep]="microsoft.containerregistry/registries/replications"
    [containerapp]="microsoft.app/containerapps"
    [containerappsenv]="microsoft.app/managedenvironments"
    [containerjob]="microsoft.app/jobs"
    [sql]="microsoft.sql/servers/databases"
    [pgsql]="microsoft.dbforpostgresql/flexibleservers"
    [cosmos]="microsoft.documentdb/databaseaccounts"
    [redis]="microsoft.cache/redis"
    [sb]="microsoft.servicebus/namespaces"
    [eh]="microsoft.eventhub/namespaces"
    [apim]="microsoft.apimanagement/service"
    [law]="microsoft.operationalinsights/workspaces"
    [kv]="microsoft.keyvault/vaults"
    [lb]="microsoft.network/loadbalancers"
    [appgw]="microsoft.network/applicationgateways"
    [pip]="microsoft.network/publicipaddresses"
    [pe]="microsoft.network/privateendpoints"
    [nic]="microsoft.network/networkinterfaces"
    [storage]="microsoft.storage/storageaccounts"
    [aks]="microsoft.containerservice/managedclusters"
    [nsg]="microsoft.network/networksecuritygroups"
    [identity]="microsoft.managedidentity/userassignedidentities"
    [rt]="microsoft.network/routetables"
)

FILTER_TYPE="${TMAP[$TYPE]}"
[[ -z "$FILTER_TYPE" && "$TYPE" != "all" ]] && die "Tipo desconhecido: $TYPE"

# ── Buscar recursos — usar --subscription explícito ───────────────────────────
RAW=$(az resource list \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RG" \
    --query "[].{id:id,name:name,type:type,location:location,tags:tags,kind:kind}" \
    -o json 2>/dev/null)

[[ -z "$RAW" ]] && die "Falha ao listar recursos do RG '$RG' (sub: $AZURE_SUBSCRIPTION_ID)"

# ── Filtrar e formatar LLD ────────────────────────────────────────────────────
python3 - << PYEOF
import json

raw        = json.loads(r"""${RAW}""")
filter_low = "${FILTER_TYPE}".lower()
all_mode   = "$TYPE" == "all"
inc_name   = "$TAG_INC_NAME".strip()
inc_value  = "$TAG_INC_VALUE".strip().lower()
exc_name   = "$TAG_EXC_NAME".strip()
exc_value  = "$TAG_EXC_VALUE".strip().lower()

SHORT = {v: k for k, v in {
$(for k in "${!TMAP[@]}"; do echo "    \"$k\": \"${TMAP[$k]}\","; done)
}.items()}

result = []
for r in raw:
    t = (r.get("type") or "").lower()
    if not all_mode and t != filter_low:
        continue
    if t not in SHORT:
        continue
    tags = r.get("tags") or {}
    if inc_name and tags.get(inc_name,"").lower() != inc_value:
        continue
    if exc_name and tags.get(exc_name,"").lower() == exc_value:
        continue
    rid = r.get("id","")
    server_name = db_name = ""
    if "/servers/" in rid.lower() and "/databases/" in rid.lower():
        parts = rid.split("/")
        try:
            i = [p.lower() for p in parts].index("servers")
            server_name = parts[i+1]; db_name = parts[-1]
        except: pass
    result.append({
        "{#RESOURCE_ID}":         rid,
        "{#RESOURCE_NAME}":       r.get("name",""),
        "{#RESOURCE_TYPE}":       r.get("type",""),
        "{#RESOURCE_TYPE_SHORT}": SHORT[t],
        "{#RESOURCE_LOCATION}":   r.get("location",""),
        "{#RESOURCE_KIND}":       r.get("kind","") or "",
        "{#RESOURCE_GROUP}":      "$RG",
        "{#SUBSCRIPTION_ID}":     "$AZURE_SUBSCRIPTION_ID",
        "{#SERVER_NAME}":         server_name,
        "{#DB_NAME}":             db_name,
        "{#TAGS}":                json.dumps(tags),
        "{#APP_NAME}":            tags.get("$TAG_APP_NAME", "") or "",
    })
print(json.dumps({"data": result}, indent=2))
PYEOF
