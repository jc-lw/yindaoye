
# mo_v14_fast.sh
# Fast controller:
#   1) reuse/create 2 usable billed projects
#   2) parallel Vertex Authorization AQ extraction
#   3) in parallel, reuse/create and verify one SOCKS5 proxy
#   4) print the full SOCKS5 credential + AQ keys to console
#   5) NO panel upload / NO key upload / NO proxy upload
#
# Compatible with the current jc-lw/yindaoye test.sh function library.
# Normal final format intentionally stays compatible with mo_v12:
#
# ================= FINAL RESULT ================
# socks5://user:pass@1.2.3.4:1080
#
# AQ....
# AQ....

set -uo pipefail

VERSION="14.0.0-fast-pipeline"
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"

REUSE_PROXY="${REUSE_PROXY:-1}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_ZONE_TRIES="${PROXY_ZONE_TRIES:-8}"
PROXY_ZONES_PER_PROJECT="${PROXY_ZONES_PER_PROJECT:-3}"
PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-180}"
PROXY_REUSE_GRACE_SECONDS="${PROXY_REUSE_GRACE_SECONDS:-3}"
PROXY_SCAN_JOBS="${PROXY_SCAN_JOBS:-6}"
PROXY_VALIDATE_JOBS="${PROXY_VALIDATE_JOBS:-6}"
PROXY_HTTP_CONNECT_TIMEOUT="${PROXY_HTTP_CONNECT_TIMEOUT:-2}"
PROXY_HTTP_MAX_TIME="${PROXY_HTTP_MAX_TIME:-4}"
PROXY_HINT_WAIT_SECONDS="${PROXY_HINT_WAIT_SECONDS:-300}"
BILLING_SCAN_JOBS="${BILLING_SCAN_JOBS:-6}"
KEY_SCAN_JOBS="${KEY_SCAN_JOBS:-4}"
KEY_SCAN_LIMIT="${KEY_SCAN_LIMIT:-12}"
BILLING_DISCOVERY_RETRIES="${BILLING_DISCOVERY_RETRIES:-3}"
BILLING_DESCRIBE_RETRIES="${BILLING_DESCRIBE_RETRIES:-3}"
BILLING_LINK_RETRIES="${BILLING_LINK_RETRIES:-4}"
BILLING_LINK_POLL_SECONDS="${BILLING_LINK_POLL_SECONDS:-24}"
NEW_PROJECT_SLOT_TRIES="${NEW_PROJECT_SLOT_TRIES:-6}"
KEY_SETUP_ATTEMPTS="${KEY_SETUP_ATTEMPTS:-2}"
KEY_SETUP_RETRY_SLEEP="${KEY_SETUP_RETRY_SLEEP:-8}"
AUTO_FIX_VERTEX_AUTH_POLICY="${AUTO_FIX_VERTEX_AUTH_POLICY:-0}"
VERTEX_POLICY_WAIT_SECONDS="${VERTEX_POLICY_WAIT_SECONDS:-20}"
KEY_FALLBACK_LIMIT="${KEY_FALLBACK_LIMIT:-8}"

[[ "$NEED_PROJECTS" =~ ^[1-9][0-9]*$ ]] || NEED_PROJECTS=2
[[ "$PROXY_SCAN_JOBS" =~ ^[1-9][0-9]*$ ]] || PROXY_SCAN_JOBS=6
[[ "$PROXY_VALIDATE_JOBS" =~ ^[1-9][0-9]*$ ]] || PROXY_VALIDATE_JOBS=6
[[ "$PROXY_HTTP_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || PROXY_HTTP_CONNECT_TIMEOUT=2
[[ "$PROXY_HTTP_MAX_TIME" =~ ^[1-9][0-9]*$ ]] || PROXY_HTTP_MAX_TIME=4
[[ "$PROXY_HINT_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || PROXY_HINT_WAIT_SECONDS=300
[[ "$BILLING_SCAN_JOBS" =~ ^[1-9][0-9]*$ ]] || BILLING_SCAN_JOBS=6
[[ "$KEY_SCAN_JOBS" =~ ^[1-9][0-9]*$ ]] || KEY_SCAN_JOBS=4
[[ "$KEY_SCAN_LIMIT" =~ ^[1-9][0-9]*$ ]] || KEY_SCAN_LIMIT=12
[[ "$PROXY_REUSE_GRACE_SECONDS" =~ ^[0-9]+$ ]] || PROXY_REUSE_GRACE_SECONDS=3
[[ "$BILLING_DISCOVERY_RETRIES" =~ ^[1-9][0-9]*$ ]] || BILLING_DISCOVERY_RETRIES=3
[[ "$BILLING_DESCRIBE_RETRIES" =~ ^[1-9][0-9]*$ ]] || BILLING_DESCRIBE_RETRIES=3
[[ "$BILLING_LINK_RETRIES" =~ ^[1-9][0-9]*$ ]] || BILLING_LINK_RETRIES=4
[[ "$BILLING_LINK_POLL_SECONDS" =~ ^[0-9]+$ ]] || BILLING_LINK_POLL_SECONDS=24
[[ "$NEW_PROJECT_SLOT_TRIES" =~ ^[1-9][0-9]*$ ]] || NEW_PROJECT_SLOT_TRIES=6
[[ "$KEY_SETUP_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || KEY_SETUP_ATTEMPTS=2
[[ "$KEY_SETUP_RETRY_SLEEP" =~ ^[0-9]+$ ]] || KEY_SETUP_RETRY_SLEEP=8
[[ "$AUTO_FIX_VERTEX_AUTH_POLICY" =~ ^[01]$ ]] || AUTO_FIX_VERTEX_AUTH_POLICY=0
[[ "$VERTEX_POLICY_WAIT_SECONDS" =~ ^[0-9]+$ ]] || VERTEX_POLICY_WAIT_SECONDS=20
[[ "$KEY_FALLBACK_LIMIT" =~ ^[1-9][0-9]*$ ]] || KEY_FALLBACK_LIMIT=8

# Keep the stable test.sh SA propagation waits untouched.
export PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-1}"
export PROJECT_CREATE_GAP="${PROJECT_CREATE_GAP:-1}"
export API_BATCH_GAP="${API_BATCH_GAP:-0}"
export API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-2}"
export API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

say(){ echo -e "${CYAN}${BOLD}[mo]${NC} $*" >&2; }
ok(){ echo -e "${GREEN}[mo] $*${NC}" >&2; }
warn(){ echo -e "${YELLOW}[mo] $*${NC}" >&2; }
err(){ echo -e "${RED}[mo] $*${NC}" >&2; }

for cmd in gcloud curl openssl timeout python3; do
  command -v "$cmd" >/dev/null 2>&1 || { err "missing command: $cmd"; exit 1; }
done

ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
[ -z "$ACCOUNT" ] && ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
[ -z "$ACCOUNT" ] || [ "$ACCOUNT" = "(unset)" ] && { err "no active gcloud account"; exit 1; }

say "version: $VERSION"
say "account: $ACCOUNT"

PROXY_OUT="/tmp/mo_proxy_$$.env"
TESTSH="/tmp/mo_testsh_$$.sh"
KEYDIR=""
BILLDIR=""
PROXY_PID=""
PROXY_HINT="/tmp/mo_proxy_candidates_$$.txt"

FINAL_ARMED=0
FINAL_PRINTED=0
PROXY_READY=0
KEY_STAGE_OK=0
VKEYS=()

cleanup(){
  rm -f "${PROXY_OUT:-}" "${TESTSH:-}" "${PROXY_HINT:-}" 2>/dev/null || true
  [ -n "${KEYDIR:-}" ] && rm -rf "$KEYDIR" 2>/dev/null || true
  [ -n "${BILLDIR:-}" ] && rm -rf "$BILLDIR" 2>/dev/null || true
}

emit_final(){
  [ "${FINAL_PRINTED:-0}" = "1" ] && return 0
  FINAL_PRINTED=1

  if [ -s "${PROXY_OUT:-}" ]; then
    # shellcheck disable=SC1090
    source "$PROXY_OUT" 2>/dev/null || true
    [ -n "${PROXY_URL:-}" ] && PROXY_READY=1
  fi

  local final_proxy="SOCKS5_FAILED"
  [ "${PROXY_READY:-0}" = "1" ] && [ -n "${PROXY_URL:-}" ] && final_proxy="$PROXY_URL"

  local final_label="PARTIAL RESULT"
  if [ "${KEY_STAGE_OK:-0}" = "1" ] && [ "${PROXY_READY:-0}" = "1" ]; then
    final_label="FINAL RESULT"
  fi

  printf '\n================ %s ================\n%s\n\n' "$final_label" "$final_proxy"
  if declare -p VKEYS >/dev/null 2>&1; then
    printf '%s\n' "${VKEYS[@]:0:${NEED_PROJECTS:-2}}"
  fi
  if [ "$final_label" != "FINAL RESULT" ]; then
    printf 'KEYS=%s/%s PROXY_READY=%s\n' "${#VKEYS[@]}" "${NEED_PROJECTS:-2}" "${PROXY_READY:-0}"
  fi
}

on_exit(){
  local rc=$?
  trap - EXIT

  if [ -n "${PROXY_PID:-}" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi

  if [ "${FINAL_ARMED:-0}" = "1" ] && [ "${FINAL_PRINTED:-0}" != "1" ]; then
    warn "main flow ended early; printing collected result"
    emit_final
  fi

  cleanup
  exit "$rc"
}
trap on_exit EXIT

wait_pid_batch(){
  local p
  for p in "$@"; do
    wait "$p" 2>/dev/null || true
  done
}

# ============================================================
# Load upstream test.sh
# ============================================================
say "download test.sh: $TESTSH_URL"
curl -fsSL "$TESTSH_URL" -o "$TESTSH" || { err "failed to download test.sh"; exit 1; }
bash -n "$TESTSH" || { err "remote test.sh has Bash syntax errors"; exit 1; }

# Disable only the exact top-level main invocation.
sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo_v13_fast.sh/' "$TESTSH"

# shellcheck disable=SC1090
source "$TESTSH" >/dev/null 2>&1 || true

# test.sh enables -Euo pipefail and an ERR trap. Keep nounset/pipefail, drop errexit/ERR trap.
set +e +E
set -u
set -o pipefail
trap - ERR 2>/dev/null || true

if ! declare -p BILLING_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then
  declare -gA BILLING_BLOCKED_APIS=()
fi
if ! declare -p PERMISSION_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then
  declare -gA PERMISSION_BLOCKED_APIS=()
fi

for fn in \
  billing_accounts_tsv \
  project_billing_enabled \
  create_projects_exact \
  ensure_vertex_key_apis \
  v27_setup_and_extract_aq_key \
  find_authorization_key_string
do
  declare -F "$fn" >/dev/null 2>&1 || { err "test.sh missing function: $fn"; exit 1; }
done

ok "test.sh function self-check passed"


# ============================================================
# Billing discovery/repair helpers
# ============================================================
# Do not trust a single transient Cloud Billing CLI failure. The user's live
# Cloud Shell logs showed billing_accounts_tsv empty once and succeeding on the
# immediate next run, so retry before declaring "no Billing Account".
mo_detect_billing_id(){
  local attempt raw bid pid acct delay

  if [ -n "${BILLING_ID:-}" ]; then
    printf '%s\n' "${BILLING_ID#billingAccounts/}"
    return 0
  fi

  for ((attempt=1; attempt<=BILLING_DISCOVERY_RETRIES; attempt++)); do
    raw=$(billing_accounts_tsv 2>/dev/null || true)
    bid=$(printf '%s\n' "$raw" | awk -F'\t' 'NF{print $1; exit}')
    bid="${bid#billingAccounts/}"
    if [ -n "$bid" ]; then
      printf '%s\n' "$bid"
      return 0
    fi

    # Fallback: an identity may be able to see/use projects even when listing
    # Billing Accounts transiently fails. Recover the attached account from any
    # accessible project instead of requiring a configured default project.
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      acct=$(gcloud billing projects describe "$pid" \
        --format='value(billingAccountName)' 2>/dev/null || true)
      acct="${acct#billingAccounts/}"
      if [ -n "$acct" ] && [ "$acct" != "None" ]; then
        printf '%s\n' "$acct"
        return 0
      fi
    done < <(gcloud projects list --format='value(projectId)' 2>/dev/null | head -n 12)

    if [ "$attempt" -lt "$BILLING_DISCOVERY_RETRIES" ]; then
      delay=$((attempt * 2))
      warn "Billing Account discovery returned empty (${attempt}/${BILLING_DISCOVERY_RETRIES}); retry in ${delay}s"
      sleep "$delay"
    fi
  done
  return 1
}

# Print: billing-account-id<TAB>true|false . Retry reads because Cloud Billing
# state can lag project creation/linking and the CLI can have transient errors.
mo_project_billing_info_retry(){
  local pid="$1" attempt info enabled acct delay
  for ((attempt=1; attempt<=BILLING_DESCRIBE_RETRIES; attempt++)); do
    info=$(gcloud billing projects describe "$pid" \
      --format='value(billingEnabled,billingAccountName)' 2>/dev/null || true)
    if [ -n "$info" ]; then
      enabled=$(printf '%s' "$info" | awk '{print $1}')
      acct=$(printf '%s' "$info" | awk '{print $2}')
      enabled=$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      acct="${acct#billingAccounts/}"
      printf '%s\t%s\n' "$acct" "$enabled"
      return 0
    fi
    if [ "$attempt" -lt "$BILLING_DESCRIBE_RETRIES" ]; then
      delay=$((attempt * 2))
      sleep "$delay"
    fi
  done
  return 1
}

# A create_projects_exact success means the Resource Manager project exists; it
# does NOT mean Cloud Billing is usable. Upstream test.sh appends the project to
# its output array before link_project_to_billing(), and ignores link failure.
# Repair the SAME project first and use billingEnabled as the authority.
mo_ensure_project_billing(){
  local pid="$1" billing_id="$2" attempt out rc elapsed step=3

  if project_billing_enabled "$pid" 2>/dev/null; then
    return 0
  fi

  for ((attempt=1; attempt<=BILLING_LINK_RETRIES; attempt++)); do
    out=$(gcloud billing projects link "$pid" \
      --billing-account="$billing_id" --quiet 2>&1); rc=$?

    # Even when gcloud reports a transport error, the backend write may have
    # succeeded. Always poll ProjectBillingInfo before deciding it failed.
    elapsed=0
    while [ "$elapsed" -le "$BILLING_LINK_POLL_SECONDS" ]; do
      if project_billing_enabled "$pid" 2>/dev/null; then
        ok "[$pid] Billing verified: billingEnabled=true"
        clear_billing_blocked_for_project "$pid" 2>/dev/null || true
        return 0
      fi
      [ "$elapsed" -ge "$BILLING_LINK_POLL_SECONDS" ] && break
      sleep "$step"
      elapsed=$((elapsed + step))
    done

    if [ "$rc" -eq 0 ]; then
      warn "[$pid] Billing link command succeeded but billingEnabled is still false; retry ${attempt}/${BILLING_LINK_RETRIES}"
    else
      warn "[$pid] Billing link attempt ${attempt}/${BILLING_LINK_RETRIES} failed: $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ' | cut -c1-260)"
    fi

    # A real billing-link quota error will not be fixed by hammering the same API.
    if declare -F is_billing_link_quota_error >/dev/null 2>&1 && is_billing_link_quota_error "$out"; then
      warn "[$pid] Cloud Billing link quota rejected this request; stop retrying this project"
      return 21
    fi

    [ "$attempt" -lt "$BILLING_LINK_RETRIES" ] && sleep $((attempt * 3))
  done
  return 1
}

# ============================================================
# Faster but equivalent Vertex Authorization key lookup.
# Upstream find_authorization_key_string describes each API key twice:
# once for serviceAccountEmail and once for restrictions. This override
# reads one JSON description per key, then calls get-key-string once.
# ============================================================
mo_key_desc_match(){
  local desc="$1"
  local expected_sa="$2"

  if command -v python3 >/dev/null 2>&1; then
    KEY_DESC_JSON="$desc" python3 - "$expected_sa" <<'PY'
import json, os, sys
expected = sys.argv[1]
try:
    d = json.loads(os.environ.get("KEY_DESC_JSON", ""))
except Exception:
    print("0 0")
    raise SystemExit(0)

bound = (d.get("serviceAccountEmail") or "").strip()
targets = ((d.get("restrictions") or {}).get("apiTargets") or [])
vertex = any(isinstance(t, dict) and t.get("service") == "aiplatform.googleapis.com" for t in targets)
print("1" if bound == expected and bound else "0", "1" if vertex else "0")
PY
    return 0
  fi

  local bound_match=0 vertex_match=0
  echo "$desc" | grep -Fq "\"serviceAccountEmail\": \"$expected_sa\"" && bound_match=1
  echo "$desc" | grep -Fq '"service": "aiplatform.googleapis.com"' && vertex_match=1
  printf '%s %s\n' "$bound_match" "$vertex_match"
}

find_authorization_key_string(){
  local project_id="$1"
  local sa_email="$2"
  local keys_json key_name api_key
  local -a candidate_names=()

  # v14: api-keys list 的 JSON 已含 restrictions/serviceAccountEmail。
  # 一次 list 后本地筛选，避免旧版对每把 key 再发一次 describe 请求。
  keys_json=$(gcloud services api-keys list \
    --project="$project_id" --format=json 2>/dev/null || true)
  [ -z "$keys_json" ] && return 1

  mapfile -t candidate_names < <(
    KEY_LIST_JSON="$keys_json" EXPECTED_SA="$sa_email" python3 - <<'PYKEY'
import json, os
try:
    rows = json.loads(os.environ.get("KEY_LIST_JSON", "[]"))
except Exception:
    rows = []
expected = os.environ.get("EXPECTED_SA", "").strip()
exact, fallback = [], []
for item in rows if isinstance(rows, list) else []:
    if not isinstance(item, dict):
        continue
    name = (item.get("name") or "").strip()
    if not name:
        continue
    targets = ((item.get("restrictions") or {}).get("apiTargets") or [])
    vertex = any(isinstance(t, dict) and t.get("service") == "aiplatform.googleapis.com" for t in targets)
    if not vertex:
        continue
    bound = (item.get("serviceAccountEmail") or "").strip()
    (exact if expected and bound == expected else fallback).append(name)
for name in exact + fallback:
    print(name)
PYKEY
  )

  [ "${#candidate_names[@]}" -gt 0 ] || return 1

  for key_name in "${candidate_names[@]}"; do
    api_key=$(gcloud services api-keys get-key-string "$key_name" \
      --format='value(keyString)' 2>/dev/null | tr -d '
' | xargs || true)
    if [[ "$api_key" == AQ.* ]]; then
      printf '%s
' "$api_key"
      return 0
    fi
  done
  return 1
}

# ============================================================
# Vertex Authorization-key failure classification / policy helpers
# ============================================================
# Return codes:
#   0  = no known hard failure
#   30 = managed org policy blocks SA-bound API keys
#   31 = permanent permission/organization-policy failure
#   32 = billing/precondition failure
#   33 = retryable quota/rate-limit condition
mo_vertex_failure_classify(){
  local log="$1"
  [ -s "$log" ] || return 0

  if grep -qiE 'constraints/iam\.managed\.disableServiceAccountApiKeyCreation|Block service account API key bindings|Organization Policy.*Authorization key' "$log"; then
    return 30
  fi
  if grep -qiE 'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|does not have permission|permission.*denied|orgpolicy\.policy\.set' "$log"; then
    return 31
  fi
  if grep -qiE 'UREQ_PROJECT_BILLING_NOT_OPEN|UREQ_PROJECT_BILLING_NOT_FOUND|billing.*(disabled|not enabled|not open)|FAILED_PRECONDITION.*billing' "$log"; then
    return 32
  fi
  if grep -qiE 'RESOURCE_EXHAUSTED|QUOTA_EXCEEDED|rate.?limit|HTTP[^0-9]*429|(^|[^0-9])429([^0-9]|$)' "$log"; then
    return 33
  fi
  return 0
}

mo_project_org_id(){
  local project="$1" org
  org=$(gcloud projects get-ancestors "$project" \
    --format='value(type,id)' 2>/dev/null | awk '$1=="organization"{print $2; exit}' || true)
  printf '%s\n' "$org"
}

# Optional least-privilege repair. Disabled by default because this changes an
# Organization Policy. When enabled, only aiplatform.googleapis.com is added to
# allowedServices for this managed constraint; the constraint is not disabled.
mo_try_fix_vertex_auth_policy(){
  local project="$1" org policy_file out rc
  [ "$AUTO_FIX_VERTEX_AUTH_POLICY" = "1" ] || return 40

  org=$(mo_project_org_id "$project")
  if [ -z "$org" ]; then
    warn "[$project] no Organization ancestor; Google does not support changing this Authorization-key org policy for projects without an organization"
    return 41
  fi

  policy_file=$(mktemp /tmp/mo_vertex_policy_XXXXXX.yaml)
  cat > "$policy_file" <<EOF
name: projects/${project}/policies/iam.managed.disableServiceAccountApiKeyCreation
spec:
  rules:
  - enforce: true
    parameters:
      allowedServices:
      - aiplatform.googleapis.com
EOF

  say "[$project] AUTO_FIX_VERTEX_AUTH_POLICY=1: allow only aiplatform.googleapis.com for SA-bound API keys"
  out=$(gcloud org-policies set-policy "$policy_file" --update-mask=spec 2>&1); rc=$?
  rm -f "$policy_file"
  if [ "$rc" -ne 0 ]; then
    warn "[$project] org-policy repair failed: $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ' | cut -c1-420)"
    return 42
  fi

  ok "[$project] org-policy update submitted; wait ${VERTEX_POLICY_WAIT_SECONDS}s before retry"
  sleep "$VERTEX_POLICY_WAIT_SECONDS"
  return 0
}

mo_vertex_attempt_project(){
  local pid="$1" outdir="$2" existing_key sa_email raw_key vkey key_try class_rc=0
  local log="$outdir/$pid.vertex.log"
  : > "$log"

  existing_key="${PREKEY_BY_PID[$pid]:-}"
  if [ -z "$existing_key" ]; then
    sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
    existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | \
      grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
  fi
  if [ -n "$existing_key" ]; then
    printf '%s\n' "$existing_key" > "$outdir/$pid.key"
    printf 'ok\n' > "$outdir/$pid.status"
    echo "[$pid] Existing AQ -> reuse: ${existing_key:0:12}..." >&2
    return 0
  fi

  if ! ensure_vertex_key_apis "$pid" "mo-v13.3-Vertex" >&2; then
    printf 'api-not-ready\n' > "$outdir/$pid.status"
    echo "[$pid] Vertex required APIs not ready" >&2
    return 1
  fi

  vkey=""
  for ((key_try=1; key_try<=KEY_SETUP_ATTEMPTS; key_try++)); do
    : > "$log"
    raw_key=$(v27_setup_and_extract_aq_key "$pid" 1 2> >(tee "$log" >&2) || true)
    vkey=$(printf '%s\n' "$raw_key" | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)

    if [ -z "$vkey" ]; then
      sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
      vkey=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | \
        grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    fi
    if [ -n "$vkey" ]; then
      printf '%s\n' "$vkey" > "$outdir/$pid.key"
      printf 'ok\n' > "$outdir/$pid.status"
      echo "[$pid] Vertex AQ ready: ${vkey:0:12}..." >&2
      return 0
    fi

    class_rc=0
    mo_vertex_failure_classify "$log" || class_rc=$?
    case "$class_rc" in
      30)
        printf 'policy-block\n' > "$outdir/$pid.status"
        echo "[$pid] HARD STOP: managed org policy blocks SA-bound Vertex Authorization keys" >&2
        if mo_try_fix_vertex_auth_policy "$pid"; then
          # Policy was intentionally changed by the caller. Retry the same project once.
          raw_key=$(v27_setup_and_extract_aq_key "$pid" 1 2> >(tee "$log" >&2) || true)
          vkey=$(printf '%s\n' "$raw_key" | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
          if [ -n "$vkey" ]; then
            printf '%s\n' "$vkey" > "$outdir/$pid.key"
            printf 'ok\n' > "$outdir/$pid.status"
            echo "[$pid] Vertex AQ ready after policy repair: ${vkey:0:12}..." >&2
            return 0
          fi
        fi
        return 30
        ;;
      31) printf 'permission-block\n' > "$outdir/$pid.status"; return 31 ;;
      32) printf 'billing-block\n' > "$outdir/$pid.status"; return 32 ;;
      33)
        # quota/rate limit can be retried; test.sh already retries internally,
        # so only use the configured outer retry here.
        ;;
      *) ;;
    esac

    if [ "$key_try" -lt "$KEY_SETUP_ATTEMPTS" ]; then
      echo "[$pid] retryable/unknown AQ failure ${key_try}/${KEY_SETUP_ATTEMPTS}; wait ${KEY_SETUP_RETRY_SLEEP}s" >&2
      sleep "$KEY_SETUP_RETRY_SLEEP"
    fi
  done

  printf 'failed\n' > "$outdir/$pid.status"
  echo "[$pid] Vertex AQ failed after ${KEY_SETUP_ATTEMPTS} retryable attempt(s)" >&2
  return 1
}

# ============================================================
# SOCKS5 helpers
# ============================================================
mo_proxy_test(){
  local proxy_url="${1:-}" proxy_h
  [ -z "$proxy_url" ] && return 1
  proxy_h="${proxy_url/socks5:\/\//socks5h:\/\/}"

  # v14: 失败代理不再每个端点最多拖 8 秒；先用 204，再用 ipify 兜底。
  curl -4 -fsS --connect-timeout "$PROXY_HTTP_CONNECT_TIMEOUT" --max-time "$PROXY_HTTP_MAX_TIME" \
    --proxy "$proxy_h" -o /dev/null \
    https://www.google.com/generate_204 >/dev/null 2>&1 && return 0

  curl -4 -fsS --connect-timeout "$PROXY_HTTP_CONNECT_TIMEOUT" --max-time "$PROXY_HTTP_MAX_TIME" \
    --proxy "$proxy_h" -o /dev/null \
    https://api.ipify.org >/dev/null 2>&1
}

mo_tcp_test(){
  local host="$1" port="$2"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

mo_wait_proxy(){
  local proxy_url="$1" host="$2" port="$3"
  local elapsed=0 step=3

  while [ "$elapsed" -lt "$PROXY_WAIT_SECONDS" ]; do
    if mo_tcp_test "$host" "$port" && mo_proxy_test "$proxy_url"; then
      return 0
    fi
    sleep "$step"
    elapsed=$((elapsed + step))
    if [ $((elapsed % 30)) -eq 0 ]; then
      say "[proxy] waiting SOCKS5: ${elapsed}/${PROXY_WAIT_SECONDS}s"
    fi
  done
  return 1
}

mo_ensure_network(){
  local project="$1"

  if gcloud compute networks describe default --project="$project" >/dev/null 2>&1; then
    echo default
    return 0
  fi

  if gcloud compute networks describe kn-proxy-net --project="$project" >/dev/null 2>&1; then
    echo kn-proxy-net
    return 0
  fi

  say "[proxy] no default VPC in $project; creating kn-proxy-net"
  if gcloud compute networks create kn-proxy-net \
      --project="$project" --subnet-mode=auto \
      --bgp-routing-mode=regional --quiet >/dev/null 2>&1; then
    echo kn-proxy-net
    return 0
  fi

  return 1
}

mo_ensure_firewall(){
  local project="$1" network="$2" port="$3" current_network
  local rule="allow-socks5-${port}"
  [ "$network" != "default" ] && rule="allow-socks5-${port}-knproxy"

  if gcloud compute firewall-rules describe "$rule" --project="$project" >/dev/null 2>&1; then
    current_network=$(gcloud compute firewall-rules describe "$rule" \
      --project="$project" --format='value(network)' 2>/dev/null || true)
    current_network=$(basename "$current_network")

    if [ -n "$current_network" ] && [ "$current_network" != "$network" ]; then
      warn "[proxy] firewall $rule belongs to $current_network; rebuilding for $network"
      gcloud compute firewall-rules delete "$rule" \
        --project="$project" --quiet >/dev/null 2>&1 || true
    else
      if gcloud compute firewall-rules update "$rule" \
          --project="$project" \
          --allow="tcp:${port}" \
          --source-ranges="0.0.0.0/0" \
          --target-tags=socks5-proxy \
          --priority=1000 \
          --quiet >/dev/null 2>&1; then
        return 0
      fi

      gcloud compute firewall-rules delete "$rule" \
        --project="$project" --quiet >/dev/null 2>&1 || true
    fi
  fi

  gcloud compute firewall-rules create "$rule" \
    --project="$project" \
    --network="$network" \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules="tcp:${port}" \
    --source-ranges="0.0.0.0/0" \
    --target-tags=socks5-proxy \
    --quiet >/dev/null 2>&1
}

mo_make_startup_script(){
  local path="$1" port="$2" user="$3" pass="$4"

  cat > "$path" <<'VM_EOF'
#!/bin/bash
set -u
exec >>/var/log/mo-microsocks-startup.log 2>&1

PORT="__PORT__"
PROXY_USER="__USER__"
PROXY_PASS="__PASS__"
export DEBIAN_FRONTEND=noninteractive

retry_cmd(){
  local n=1
  while [ "$n" -le 3 ]; do
    "$@" && return 0
    sleep $((n * 3))
    n=$((n + 1))
  done
  return 1
}

systemctl stop microsocks >/dev/null 2>&1 || true

# One apt update only. Prefer the Debian package; compile only as fallback.
if retry_cmd apt-get update -qq; then
  if retry_cmd apt-get install -y --no-install-recommends ca-certificates microsocks; then
    BIN=$(command -v microsocks || true)
    [ -n "$BIN" ] && install -m 0755 "$BIN" /usr/local/bin/microsocks
  else
    retry_cmd apt-get install -y --no-install-recommends ca-certificates build-essential git
    rm -rf /opt/microsocks
    retry_cmd git clone --depth 1 https://github.com/rofl0r/microsocks.git /opt/microsocks
    make -C /opt/microsocks
    install -m 0755 /opt/microsocks/microsocks /usr/local/bin/microsocks
  fi
fi

test -x /usr/local/bin/microsocks || exit 1

cat > /etc/systemd/system/microsocks.service <<SERVICE_EOF
[Unit]
Description=MicroSocks SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/microsocks -p ${PORT} -u ${PROXY_USER} -P ${PROXY_PASS}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable microsocks >/dev/null 2>&1 || true
systemctl restart microsocks
VM_EOF

  sed -i \
    -e "s/__PORT__/${port}/g" \
    -e "s/__USER__/${user}/g" \
    -e "s/__PASS__/${pass}/g" "$path"
}

mo_write_proxy_file(){
  local outfile="$1" url="$2" hostport="$3" adspower="$4" project="$5" instance="$6" zone="$7"
  {
    printf 'PROXY_URL=%q
' "$url"
    printf 'PROXY_HOSTPORT=%q
' "$hostport"
    printf 'PROXY_ADSPOWER=%q
' "$adspower"
    printf 'PROXY_PROJECT=%q
' "$project"
    printf 'PROXY_INSTANCE=%q
' "$instance"
    printf 'PROXY_ZONE=%q
' "$zone"
  } > "$outfile"
}

mo_save_proxy(){
  mo_write_proxy_file "$PROXY_OUT" "$@"
}

mo_proxy_metadata_creds(){
  local project="$1" instance="$2" zone="$3"
  local meta

  meta=$(timeout 12 gcloud compute instances describe "$instance" \
    --project="$project" --zone="$zone" \
    --format=json 2>/dev/null || true)
  [ -z "$meta" ] && return 1

  if command -v python3 >/dev/null 2>&1; then
    VM_META_JSON="$meta" python3 - <<'PY'
import json, os
try:
    d = json.loads(os.environ.get("VM_META_JSON", ""))
except Exception:
    raise SystemExit(1)
items = ((d.get("metadata") or {}).get("items") or [])
m = {}
for item in items:
    if isinstance(item, dict) and item.get("key"):
        m[item["key"]] = item.get("value", "")
u = m.get("kn-proxy-user", "")
p = m.get("kn-proxy-pass", "")
if not u or not p:
    raise SystemExit(1)
print(u)
print(p)
PY
    return $?
  fi

  local user pass
  user=$(timeout 12 gcloud compute instances describe "$instance"     --project="$project" --zone="$zone"     --format='value(metadata.items.filter("key:kn-proxy-user").extract("value").flatten())'     2>/dev/null || true)
  pass=$(timeout 12 gcloud compute instances describe "$instance"     --project="$project" --zone="$zone"     --format='value(metadata.items.filter("key:kn-proxy-pass").extract("value").flatten())'     2>/dev/null || true)
  [ -n "$user" ] && [ -n "$pass" ] || return 1
  printf '%s\n%s\n' "$user" "$pass"
}

mo_validate_proxy_candidate(){
  local project="$1" name="$2" zone="$3" ip="$4" result_file="${5:-$PROXY_OUT}"
  local creds user pass url

  [ -z "$project" ] || [ -z "$name" ] || [ -z "$zone" ] || [ -z "$ip" ] && return 1
  zone=$(basename "$zone")

  creds=$(mo_proxy_metadata_creds "$project" "$name" "$zone" || true)
  user=$(printf '%s
' "$creds" | sed -n '1p')
  pass=$(printf '%s
' "$creds" | sed -n '2p')
  [ -z "$user" ] || [ -z "$pass" ] && return 1

  url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"

  if mo_proxy_test "$url"; then
    mo_write_proxy_file "$result_file" "$url" "${ip}:${PROXY_PORT}" \
      "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$name" "$zone"
    return 0
  fi

  [ "$PROXY_REUSE_GRACE_SECONDS" -le 0 ] && return 1
  sleep "$PROXY_REUSE_GRACE_SECONDS"

  if mo_proxy_test "$url"; then
    mo_write_proxy_file "$result_file" "$url" "${ip}:${PROXY_PORT}" \
      "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$name" "$zone"
    return 0
  fi
  return 1
}

mo_find_reusable_proxy(){
  local candidates=("$@")
  local project rows file
  local jobs=()
  local scan_dir candidate_file

  scan_dir=$(mktemp -d /tmp/mo_proxy_scan_XXXXXX)
  candidate_file="$scan_dir/candidates.all"
  : > "$candidate_file"

  # 1) 各项目 instances list 有界并行。
  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue
    (
      rows=$(timeout 12 gcloud compute instances list \
        --project="$project" \
        --filter='name~socks5-node AND status=RUNNING' \
        --format='value(name,zone,networkInterfaces[0].accessConfigs[0].natIP)' \
        2>/dev/null || true)
      if [ -n "$rows" ]; then
        file="$scan_dir/list_${project}.tsv"
        while read -r name zone ip; do
          [ -n "${name:-}" ] && [ -n "${ip:-}" ] && \
            printf '%s	%s	%s	%s
' "$project" "$name" "$zone" "$ip"
        done <<< "$rows" > "$file"
      fi
    ) &
    jobs+=("$!")
    if [ "${#jobs[@]}" -ge "$PROXY_SCAN_JOBS" ]; then
      wait_pid_batch "${jobs[@]}"
      jobs=()
    fi
  done
  [ "${#jobs[@]}" -gt 0 ] && wait_pid_batch "${jobs[@]}"

  cat "$scan_dir"/list_*.tsv 2>/dev/null > "$candidate_file" || true
  if [ ! -s "$candidate_file" ]; then
    rm -rf "$scan_dir"
    return 1
  fi

  # 2) v14: 旧代理“读取 metadata + 真实 SOCKS5 请求”也有界并行。
  #    旧版这里串行，多个失效 VM 会把 3~8 秒 grace 逐个累加。
  jobs=()
  local idx=0 batch_start=1 result_file
  while IFS=$'	' read -r project name zone ip; do
    idx=$((idx + 1))
    result_file="$scan_dir/result_${idx}.env"
    ( mo_validate_proxy_candidate "$project" "$name" "$zone" "$ip" "$result_file" ) &
    jobs+=("$!")

    if [ "${#jobs[@]}" -ge "$PROXY_VALIDATE_JOBS" ]; then
      wait_pid_batch "${jobs[@]}"
      jobs=()
      for ((j=batch_start; j<=idx; j++)); do
        if [ -s "$scan_dir/result_${j}.env" ]; then
          cp "$scan_dir/result_${j}.env" "$PROXY_OUT"
          # shellcheck disable=SC1090
          source "$PROXY_OUT" 2>/dev/null || true
          ok "[proxy] reuse verified: ${PROXY_INSTANCE:-unknown} / ${PROXY_PROJECT:-unknown} / ${PROXY_HOSTPORT:-unknown}"
          rm -rf "$scan_dir"
          return 0
        fi
      done
      batch_start=$((idx + 1))
    fi
  done < "$candidate_file"

  [ "${#jobs[@]}" -gt 0 ] && wait_pid_batch "${jobs[@]}"
  for ((j=batch_start; j<=idx; j++)); do
    if [ -s "$scan_dir/result_${j}.env" ]; then
      cp "$scan_dir/result_${j}.env" "$PROXY_OUT"
      # shellcheck disable=SC1090
      source "$PROXY_OUT" 2>/dev/null || true
      ok "[proxy] reuse verified: ${PROXY_INSTANCE:-unknown} / ${PROXY_PROJECT:-unknown} / ${PROXY_HOSTPORT:-unknown}"
      rm -rf "$scan_dir"
      return 0
    fi
  done

  rm -rf "$scan_dir"
  return 1
}

mo_show_serial_tail(){
  local project="$1" instance="$2" zone="$3"
  warn "[proxy] startup failed; serial log tail follows"
  gcloud compute instances get-serial-port-output "$instance" \
    --project="$project" --zone="$zone" --port=1 2>/dev/null | tail -n 12 >&2 || true
}

build_proxy(){
  local candidates=("$@")
  local project startup user pass url ip instance zone vm_out rc
  local attempt_total=0 project_attempt candidate_index=0
  local network billing_hint enable_out enable_rc
  local zones try_zone

  if [ "$REUSE_PROXY" != "0" ]; then
    say "[proxy] parallel inventory scan across ${#candidates[@]} project(s)"
    if mo_find_reusable_proxy "${candidates[@]}"; then
      return 0
    fi
  fi

  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue
    candidate_index=$((candidate_index + 1))

    # This is informational only. Failure does not block the real VM attempt.
    billing_hint="unknown"
    if project_billing_enabled "$project" 2>/dev/null; then
      billing_hint="true"
    fi
    say "[proxy] create candidate $candidate_index/${#candidates[@]}: $project (billingEnabled=$billing_hint)"

    user="usr$(openssl rand -hex 4)"
    pass="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    startup="/tmp/mo_startup_$$.sh"
    mo_make_startup_script "$startup" "$PROXY_PORT" "$user" "$pass"

    zones=(
      us-west1-a us-west1-b us-west1-c
      us-central1-a us-central1-b us-central1-c
      us-east1-b us-east1-c us-east1-d
      us-east4-a us-east4-b us-east4-c
      us-east5-a us-east5-b us-east5-c
      us-west2-a us-west2-b us-west2-c
      us-west3-a us-west3-b us-west3-c
      us-west4-a us-west4-b us-west4-c
      us-south1-a us-south1-b us-south1-c
    )

    if [ "${PROXY_SHUFFLE_ZONES:-1}" = "1" ] && command -v shuf >/dev/null 2>&1; then
      mapfile -t zones < <(printf '%s\n' "${zones[@]}" | shuf)
    fi

    project_attempt=0
    network="default"

    for try_zone in "${zones[@]}"; do
      zone="$try_zone"

      [ "$attempt_total" -ge "$PROXY_ZONE_TRIES" ] && break 2
      [ "$project_attempt" -ge "$PROXY_ZONES_PER_PROJECT" ] && break

      attempt_total=$((attempt_total + 1))
      project_attempt=$((project_attempt + 1))
      instance="socks5-node-$(date +%s)-${attempt_total}"

      say "[proxy] [$project] VM-first create $zone (total ${attempt_total}/${PROXY_ZONE_TRIES})"

      vm_out=$(gcloud compute instances create "$instance" \
        --project="$project" \
        --zone="$zone" \
        --machine-type=e2-micro \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=socks5-proxy \
        --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
        --metadata-from-file=startup-script="$startup" \
        --quiet 2>&1)
      rc=$?

      # v14: Compute API 若刚启用，不再无条件 sleep 30 秒。
      # 每几秒重试同一 VM；API 提前传播就提前继续，最长等待仍受控。
      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE \
          'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
        warn "[proxy] [$project] Compute API disabled; enable and poll propagation"
        enable_out=$(gcloud services enable compute.googleapis.com \
          --project="$project" --quiet 2>&1)
        enable_rc=$?
        [ "$enable_rc" -ne 0 ] && \
          warn "[proxy] [$project] enable returned: $(echo "$enable_out" | tail -n 3 | tr '\n' ' ' | cut -c1-220)"

        for propagate_try in 1 2 3 4 5 6; do
          sleep $(( propagate_try < 4 ? propagate_try + 2 : 6 ))
          vm_out=$(gcloud compute instances create "$instance" \
            --project="$project" \
            --zone="$zone" \
            --machine-type=e2-micro \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --tags=socks5-proxy \
            --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
            --metadata-from-file=startup-script="$startup" \
            --quiet 2>&1)
          rc=$?
          [ "$rc" -eq 0 ] && break
          echo "$vm_out" | grep -qiE \
            'SERVICE_DISABLED|has not been used in project .* before or it is disabled' || break
        done
      fi

      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE \
          'default network.*not found|network.*default.*not found|resource.*default.*not found'; then
        network=$(mo_ensure_network "$project" || true)
        if [ -n "$network" ]; then
          vm_out=$(gcloud compute instances create "$instance" \
            --project="$project" \
            --zone="$zone" \
            --machine-type=e2-micro \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --tags=socks5-proxy \
            --network="$network" \
            --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
            --metadata-from-file=startup-script="$startup" \
            --quiet 2>&1)
          rc=$?
        fi
      fi

      if [ "$rc" -ne 0 ]; then
        if echo "$vm_out" | grep -qiE \
            'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable|resource pool exhausted'; then
          warn "[proxy] [$project] $zone out of stock; next zone"
          continue
        fi

        if echo "$vm_out" | grep -qiE \
            'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
          warn "[proxy] [$project] Compute still unavailable; next project"
          break
        fi

        if echo "$vm_out" | grep -qiE \
            'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|FAILED_PRECONDITION|UREQ_PROJECT_BILLING_NOT_OPEN|UREQ_PROJECT_BILLING_NOT_FOUND|billing|BILLING|QUOTA_EXCEEDED|quota.*exceeded'; then
          warn "[proxy] [$project] Billing/permission/quota rejected VM; next project"
          break
        fi

        warn "[proxy] [$project] $zone create failed; next zone: $(echo "$vm_out" | tail -n1 | cut -c1-180)"
        sleep 2
        continue
      fi

      ok "[proxy] VM created: $instance / $project / $zone"

      # v14: 一次 describe 同时拿公网 IP + 网络，旧版这里有两次 API 往返。
      vm_info=$(gcloud compute instances describe "$instance" \
        --project="$project" --zone="$zone" \
        --format='value(networkInterfaces[0].accessConfigs[0].natIP,networkInterfaces[0].network)' \
        2>/dev/null || true)
      read -r ip network <<< "$vm_info"
      network=$(basename "${network:-default}")
      [ -z "$network" ] && network="default"

      if ! mo_ensure_firewall "$project" "$network" "$PROXY_PORT"; then
        warn "[proxy] firewall first attempt failed; retry in 3s"
        sleep 3
        mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      fi

      if [ -z "$ip" ]; then
        warn "[proxy] VM has no public IPv4; delete and continue"
        gcloud compute instances delete "$instance" \
          --project="$project" --zone="$zone" \
          --delete-disks=all --quiet >/dev/null 2>&1 || true
        continue
      fi

      url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"
      say "[proxy] waiting microsocks + firewall + authenticated request: ${ip}:${PROXY_PORT}"

      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" \
          "${ip}:${PROXY_PORT}:${user}:${pass}" \
          "$project" "$instance" "$zone"
        ok "[proxy] verified: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      warn "[proxy] first wait failed; repair firewall + reset VM once"
      mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      gcloud compute instances reset "$instance" \
        --project="$project" --zone="$zone" --quiet >/dev/null 2>&1 || true

      sleep 8

      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" \
          "${ip}:${PROXY_PORT}:${user}:${pass}" \
          "$project" "$instance" "$zone"
        ok "[proxy] fallback repair verified: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      mo_show_serial_tail "$project" "$instance" "$zone"
      gcloud compute instances delete "$instance" \
        --project="$project" --zone="$zone" \
        --delete-disks=all --quiet >/dev/null 2>&1 || true
    done

    rm -f "$startup"
  done

  err "[proxy] all candidate projects failed"
  return 1
}

# v14 pipeline: 代理任务在 Stage 1 就启动。
# 先并行扫描旧代理；若没有可复用代理，就等待 Stage 1 发布优先建机项目，
# 然后继续创建。这样 Billing/Key 项目准备与代理扫描真正重叠。
proxy_pipeline(){
  local early_candidates=("$@")
  local create_candidates=() saved_reuse="$REUSE_PROXY"
  local waited=0

  if [ "$REUSE_PROXY" != "0" ] && [ "${#early_candidates[@]}" -gt 0 ]; then
    say "[parallel/proxy] early reusable scan across ${#early_candidates[@]} project(s)"
    if mo_find_reusable_proxy "${early_candidates[@]}"; then
      return 0
    fi
  fi

  say "[parallel/proxy] no reusable proxy yet; waiting preferred create candidates from Stage 1"
  while [ "$waited" -lt "$PROXY_HINT_WAIT_SECONDS" ]; do
    [ -s "$PROXY_HINT" ] && break
    sleep 1
    waited=$((waited + 1))
  done

  if [ -s "$PROXY_HINT" ]; then
    mapfile -t create_candidates < <(awk 'NF && !seen[$0]++' "$PROXY_HINT")
  else
    warn "[parallel/proxy] candidate hint timed out; fall back to accessible projects"
    create_candidates=("${early_candidates[@]}")
  fi

  [ "${#create_candidates[@]}" -gt 0 ] || return 1
  REUSE_PROXY=0
  build_proxy "${create_candidates[@]}"
  local rc=$?
  REUSE_PROXY="$saved_reuse"
  return "$rc"
}

# ============================================================
# Stage 1: Billing / Project inventory
# ============================================================
say "================ Stage 1: Billing / Project ================"

# v14: 先拿账号项目并立即启动代理流水线；Billing discovery 与代理扫描重叠。
mapfile -t ALL_ACCESSIBLE_PIDS < <(
  gcloud projects list --format='value(projectId)' 2>/dev/null |
  awk 'NF && !seen[$0]++'
)

DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
[ "$DEFAULT_PROJECT" = "(unset)" ] && DEFAULT_PROJECT=""

mapfile -t EARLY_PROXY_PIDS < <(
  printf '%s\n' "$DEFAULT_PROJECT" "${ALL_ACCESSIBLE_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

FINAL_ARMED=1
if [ "${#EARLY_PROXY_PIDS[@]}" -gt 0 ]; then
  say "[parallel] start proxy pipeline before Billing discovery"
  proxy_pipeline "${EARLY_PROXY_PIDS[@]}" &
  PROXY_PID=$!
fi

BILLING_ID="${BILLING_ID:-}"
BILLING_ID=$(mo_detect_billing_id) || BILLING_ID=""
[ -z "$BILLING_ID" ] && { err "no Billing Account found after ${BILLING_DISCOVERY_RETRIES} attempts"; exit 1; }
say "Billing Account selected: $BILLING_ID"

# Billing 直接用 `gcloud billing projects list` 返回的 billingEnabled；
# 公共路径不再对每个项目逐个 `billing projects describe`。
SELECTED_BILLED_PIDS=()
SELECTED_LINKED_PIDS=()
OTHER_BILLED_PIDS=()
OTHER_LINKED_PIDS=()

BILLING_LIST_RAW=$(gcloud billing projects list --billing-account="$BILLING_ID" \
  --format='value(projectId,billingEnabled)' 2>/dev/null)
BILLING_LIST_RC=$?

if [ "$BILLING_LIST_RC" -eq 0 ]; then
  while read -r pid enabled; do
    [ -z "${pid:-}" ] && continue
    enabled=$(printf '%s' "${enabled:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    SELECTED_LINKED_PIDS+=("$pid")
    [ "$enabled" = "true" ] && SELECTED_BILLED_PIDS+=("$pid")
  done <<< "$BILLING_LIST_RAW"
  say "fast Billing inventory: linked=${#SELECTED_LINKED_PIDS[@]} enabled=${#SELECTED_BILLED_PIDS[@]}"
else
  # 只有 Billing list 本身异常时才走逐项目 describe 兜底。
  warn "Billing account project-list failed; fallback to parallel per-project describe"
  BILLDIR=$(mktemp -d /tmp/mo_billing_XXXXXX)
  jobs=()
  for pid in "${ALL_ACCESSIBLE_PIDS[@]}"; do
    (
      info=$(mo_project_billing_info_retry "$pid" || true)
      [ -n "$info" ] && printf '%s\n' "$info" > "$BILLDIR/$pid.tsv"
    ) &
    jobs+=("$!")
    if [ "${#jobs[@]}" -ge "$BILLING_SCAN_JOBS" ]; then
      wait_pid_batch "${jobs[@]}"
      jobs=()
    fi
  done
  [ "${#jobs[@]}" -gt 0 ] && wait_pid_batch "${jobs[@]}"

  for pid in "${ALL_ACCESSIBLE_PIDS[@]}"; do
    [ -s "$BILLDIR/$pid.tsv" ] || continue
    IFS=$'\t' read -r acct enabled < "$BILLDIR/$pid.tsv"
    if [ "$acct" = "$BILLING_ID" ]; then
      SELECTED_LINKED_PIDS+=("$pid")
      [ "$enabled" = "true" ] && SELECTED_BILLED_PIDS+=("$pid")
    elif [ -n "$acct" ] && [ "$acct" != "None" ]; then
      OTHER_LINKED_PIDS+=("$pid")
      [ "$enabled" = "true" ] && OTHER_BILLED_PIDS+=("$pid")
    fi
  done
fi

# Existing AQ 可以从已关联项目直接复用；新建 AQ 优先 billingEnabled=true。
mapfile -t KEY_REUSE_CANDIDATES < <(
  printf '%s\n' \
    "${SELECTED_BILLED_PIDS[@]}" \
    "${SELECTED_LINKED_PIDS[@]}" \
    "${OTHER_BILLED_PIDS[@]}" \
    "${OTHER_LINKED_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

mapfile -t KEY_WORK_CANDIDATES < <(
  printf '%s\n' "${SELECTED_BILLED_PIDS[@]}" "${OTHER_BILLED_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

declare -A PREKEY_BY_PID=()
KEY_PIDS=()

if [ "${#KEY_REUSE_CANDIDATES[@]}" -gt 0 ]; then
  say "checking existing Vertex AQ in ${#KEY_REUSE_CANDIDATES[@]} linked/billed project(s)..."
  KEY_SCAN_DIR=$(mktemp -d /tmp/mo_prekeys_XXXXXX)
  scan_count=0
  start_idx=0

  while [ "$start_idx" -lt "${#KEY_REUSE_CANDIDATES[@]}" ] && \
        [ "${#KEY_PIDS[@]}" -lt "$NEED_PROJECTS" ] && \
        [ "$scan_count" -lt "$KEY_SCAN_LIMIT" ]; do
    jobs=()
    batch_pids=()
    n=0

    while [ "$n" -lt "$KEY_SCAN_JOBS" ] && \
          [ "$start_idx" -lt "${#KEY_REUSE_CANDIDATES[@]}" ] && \
          [ "$scan_count" -lt "$KEY_SCAN_LIMIT" ]; do
      pid="${KEY_REUSE_CANDIDATES[$start_idx]}"
      start_idx=$((start_idx + 1))
      scan_count=$((scan_count + 1))
      batch_pids+=("$pid")

      (
        sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
        existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | \
          grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
        [ -n "$existing_key" ] && printf '%s\n' "$existing_key" > "$KEY_SCAN_DIR/$pid.key"
      ) &
      jobs+=("$!")
      n=$((n + 1))
    done

    wait_pid_batch "${jobs[@]}"
    for pid in "${batch_pids[@]}"; do
      if [ -s "$KEY_SCAN_DIR/$pid.key" ]; then
        existing_key=$(head -n1 "$KEY_SCAN_DIR/$pid.key")
        if [ -z "${PREKEY_BY_PID[$pid]:-}" ]; then
          PREKEY_BY_PID["$pid"]="$existing_key"
          KEY_PIDS+=("$pid")
          ok "existing AQ: $pid / ${existing_key:0:12}..."
          [ "${#KEY_PIDS[@]}" -ge "$NEED_PROJECTS" ] && break
        fi
      fi
    done
  done
  rm -rf "$KEY_SCAN_DIR"
fi

NEED_SLOTS=$((NEED_PROJECTS - ${#KEY_PIDS[@]}))
WORK_PIDS=()

if [ "$NEED_SLOTS" -gt 0 ]; then
  for pid in "${KEY_WORK_CANDIDATES[@]}"; do
    [ -n "${PREKEY_BY_PID[$pid]:-}" ] && continue
    WORK_PIDS+=("$pid")
    ok "reuse billingEnabled project for new AQ work: $pid"
    [ "${#WORK_PIDS[@]}" -ge "$NEED_SLOTS" ] && break
  done
fi

# IMPORTANT: before creating ANY new project, repair projects that are already
# linked to the selected Billing Account but currently report billingEnabled != true.
# This handles transient/lagging Billing state and prevents abandoning an existing
# project after a previous Vertex attempt failed.
if [ $(( ${#KEY_PIDS[@]} + ${#WORK_PIDS[@]} )) -lt "$NEED_PROJECTS" ]; then
  say "existing usable projects are short; repair selected Billing-linked projects before creating anything new"
  for pid in "${SELECTED_LINKED_PIDS[@]}"; do
    [ -z "$pid" ] && continue
    [ -n "${PREKEY_BY_PID[$pid]:-}" ] && continue

    already=0
    for wp in "${WORK_PIDS[@]}"; do
      [ "$wp" = "$pid" ] && { already=1; break; }
    done
    [ "$already" = "1" ] && continue

    billing_fix_rc=0
    mo_ensure_project_billing "$pid" "$BILLING_ID" || billing_fix_rc=$?
    if [ "$billing_fix_rc" -eq 0 ]; then
      WORK_PIDS+=("$pid")
      ok "repaired/revalidated existing Billing-linked project for AQ work: $pid"
    elif [ "$billing_fix_rc" -eq 21 ]; then
      warn "[$pid] Billing-link quota hit while repairing an EXISTING project; do not create replacement projects"
      BILLING_HARD_STOP=1
      break
    else
      warn "[$pid] existing Billing-linked project is still unusable after repair; keep it and try other existing projects"
    fi
    [ $(( ${#KEY_PIDS[@]} + ${#WORK_PIDS[@]} )) -ge "$NEED_PROJECTS" ] && break
  done
fi

# Only create when the actual usable count is still short. Create ONE slot at a
# time because upstream create_projects_exact counts project creation success,
# not billing-link success. After each create, repair/poll billing on that SAME
# project before deciding whether another project is needed.
BILLING_HARD_STOP="${BILLING_HARD_STOP:-0}"
create_round=0
while [ "$BILLING_HARD_STOP" != "1" ] && \
      [ $(( ${#KEY_PIDS[@]} + ${#WORK_PIDS[@]} )) -lt "$NEED_PROJECTS" ] && \
      [ "$create_round" -lt "$NEW_PROJECT_SLOT_TRIES" ]; do
  create_round=$((create_round + 1))
  say "usable key projects=$(( ${#KEY_PIDS[@]} + ${#WORK_PIDS[@]} ))/${NEED_PROJECTS}; create/repair one missing slot (${create_round}/${NEW_PROJECT_SLOT_TRIES})"

  ONE_NEW=()
  create_projects_exact 1 "$BILLING_ID" ONE_NEW "mo-v13.2-slot${create_round}" || true
  if [ "${#ONE_NEW[@]}" -eq 0 ]; then
    warn "no project returned for slot ${create_round}; continue"
    continue
  fi

  pid="${ONE_NEW[0]}"
  billing_fix_rc=0
  mo_ensure_project_billing "$pid" "$BILLING_ID" || billing_fix_rc=$?
  if [ "$billing_fix_rc" -eq 0 ]; then
    WORK_PIDS+=("$pid")
    SELECTED_LINKED_PIDS+=("$pid")
    SELECTED_BILLED_PIDS+=("$pid")
    ok "new usable billed project accepted: $pid"
  elif [ "$billing_fix_rc" -eq 21 ]; then
    warn "Cloud Billing link quota is a hard stop for additional new-project slots; stop creating more projects"
    break
  else
    warn "new project $pid exists but billing is not usable; keep project, do not count it as a Key slot"
  fi
done

mapfile -t KEY_PROJECTS < <(
  printf '%s\n' "${KEY_PIDS[@]}" "${WORK_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)
KEY_PROJECTS=("${KEY_PROJECTS[@]:0:$NEED_PROJECTS}")

if [ "${#KEY_PROJECTS[@]}" -lt "$NEED_PROJECTS" ]; then
  err "could not determine $NEED_PROJECTS usable key projects (found ${#KEY_PROJECTS[@]})"
  err "diagnostic: selected billing linked=${#SELECTED_LINKED_PIDS[@]} billingEnabled=${#SELECTED_BILLED_PIDS[@]}"
  exit 1
fi

say "final key projects (${#KEY_PROJECTS[@]}): ${KEY_PROJECTS[*]}"

# ============================================================
# Publish preferred proxy-create candidates to the Stage-1 proxy pipeline.
# If an old proxy was already found, the pipeline has already exited successfully.
# Otherwise it starts VM creation now while Stage 2 extracts keys in parallel.
# ============================================================
mapfile -t PROXY_CREATE_PIDS < <(
  printf '%s\n' \
    "$DEFAULT_PROJECT" \
    "${KEY_PROJECTS[@]}" \
    "${ALL_ACCESSIBLE_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

printf '%s\n' "${PROXY_CREATE_PIDS[@]}" > "$PROXY_HINT"
say "[parallel] published proxy create candidates; Vertex key extraction continues"

# If there were no accessible projects when Stage 1 began, start directly now.
if [ -z "${PROXY_PID:-}" ] && [ "${#PROXY_CREATE_PIDS[@]}" -gt 0 ]; then
  proxy_pipeline "${PROXY_CREATE_PIDS[@]}" &
  PROXY_PID=$!
fi

# ============================================================
# Stage 2: Vertex AQ keys, parallel per project + policy-aware fallback
# ============================================================
say "================ Stage 2: Vertex Key ======================="

KEYDIR=$(mktemp -d /tmp/mo_keys_XXXXXX)
declare -A TRIED_KEY_PROJECTS=()
KPIDS=()

# Initial two fixed projects run in parallel.
for pid in "${KEY_PROJECTS[@]}"; do
  TRIED_KEY_PROJECTS["$pid"]=1
  ( mo_vertex_attempt_project "$pid" "$KEYDIR" || true ) &
  KPIDS+=("$!")
done
wait_pid_batch "${KPIDS[@]}"

mo_collect_vertex_keys(){
  VKEYS=()
  local p k old duplicate
  # Preserve intended project order first, then any fallback projects.
  for p in "${KEY_PROJECTS[@]}" "${KEY_FALLBACK_USED[@]:-}"; do
    [ -n "$p" ] || continue
    [ -s "$KEYDIR/$p.key" ] || continue
    k=$(head -n1 "$KEYDIR/$p.key")
    [ -n "$k" ] || continue
    duplicate=0
    for old in "${VKEYS[@]}"; do [ "$k" = "$old" ] && { duplicate=1; break; }; done
    [ "$duplicate" = "0" ] && VKEYS+=("$k")
    [ "${#VKEYS[@]}" -ge "$NEED_PROJECTS" ] && break
  done
}

KEY_FALLBACK_USED=()
mo_collect_vertex_keys

# If one of the initial projects fails, try OTHER EXISTING billingEnabled projects
# before even considering a new project. A hard managed-policy failure never gets
# retried on the same project.
fallback_count=0
if [ "${#VKEYS[@]}" -lt "$NEED_PROJECTS" ]; then
  for pid in "${KEY_WORK_CANDIDATES[@]}"; do
    [ "${#VKEYS[@]}" -ge "$NEED_PROJECTS" ] && break
    [ -n "${TRIED_KEY_PROJECTS[$pid]:-}" ] && continue
    fallback_count=$((fallback_count + 1))
    [ "$fallback_count" -gt "$KEY_FALLBACK_LIMIT" ] && break

    say "Vertex fallback: try existing billingEnabled project $pid (${fallback_count}/${KEY_FALLBACK_LIMIT})"
    TRIED_KEY_PROJECTS["$pid"]=1
    KEY_FALLBACK_USED+=("$pid")
    mo_vertex_attempt_project "$pid" "$KEYDIR" || true
    mo_collect_vertex_keys
  done
fi

# Diagnose hard blockers. Do NOT create replacement projects after seeing the
# managed policy blocker: Google-managed default behavior is restrictive, so
# blind project creation can just repeat the same deterministic failure.
POLICY_BLOCKED_PIDS=()
PERMISSION_BLOCKED_PIDS=()
for pid in "${!TRIED_KEY_PROJECTS[@]}"; do
  status=$(cat "$KEYDIR/$pid.status" 2>/dev/null || true)
  [ "$status" = "policy-block" ] && POLICY_BLOCKED_PIDS+=("$pid")
  [ "$status" = "permission-block" ] && PERMISSION_BLOCKED_PIDS+=("$pid")
done

KEY_STAGE_OK=1
if [ "${#VKEYS[@]}" -lt "$NEED_PROJECTS" ]; then
  KEY_STAGE_OK=0
  err "Vertex key stage: got ${#VKEYS[@]}/$NEED_PROJECTS"

  if [ "${#POLICY_BLOCKED_PIDS[@]}" -gt 0 ]; then
    err "hard policy blocker on: ${POLICY_BLOCKED_PIDS[*]}"
    err "constraint: iam.managed.disableServiceAccountApiKeyCreation"
    err "do not retry or create random replacement projects; allow aiplatform.googleapis.com in that managed policy (Organization project), or use another project where the policy permits Authorization keys"
    if [ "$AUTO_FIX_VERTEX_AUTH_POLICY" != "1" ]; then
      err "optional: rerun with AUTO_FIX_VERTEX_AUTH_POLICY=1 only if you are authorized to change Organization Policy"
    fi
  fi
  [ "${#PERMISSION_BLOCKED_PIDS[@]}" -gt 0 ] && err "permission blocker on: ${PERMISSION_BLOCKED_PIDS[*]}"
else
  VKEYS=("${VKEYS[@]:0:$NEED_PROJECTS}")
  ok "Vertex key stage complete: ${#VKEYS[@]}/$NEED_PROJECTS"
fi

# ============================================================
# Stage 3: wait for parallel SOCKS5 task and verify once more
# ============================================================
say "================ Stage 3: SOCKS5 ==========================="

wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""

if [ -s "$PROXY_OUT" ]; then
  # shellcheck disable=SC1090
  source "$PROXY_OUT" 2>/dev/null || true

  if mo_proxy_test "${PROXY_URL:-}"; then
    PROXY_READY=1
  else
    PROXY_READY=0
    warn "final authenticated SOCKS5 verification failed"
  fi
fi

# ============================================================
# Stage 4: output
# ============================================================
emit_final

FINAL_RC=0
[ "$KEY_STAGE_OK" = "1" ] || FINAL_RC=1
[ "$PROXY_READY" = "1" ] || FINAL_RC=1

exit "$FINAL_RC"
