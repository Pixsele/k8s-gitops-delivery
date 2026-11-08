#!/bin/bash

NAMESPACE="default"
SAVE=false

while [[ $# -gt 0  ]]; do
        case "$1" in
                --namespace)
                [[ -n "${2:-}" ]] || { echo "Help: [--namespace <ns>] [--save]"; exit 1; }
                NAMESPACE="$2"
                shift 2
                ;;
                --save)
                SAVE=true
                shift
                ;;
                *)
                echo "Unknown option: $1"
                echo "Help: [--namespace <ns>] [--save]"
                exit 1
                ;;
        esac
done

report() {
        echo "=== KUBERNETES CLUSTER REPORT [$(date '+%Y-%m-%d %H:%M')] ==="
        echo "Check namespace: $NAMESPACE"
        printf "[+] Checking kubectl... "
        if ! command -v kubectl > /dev/null 2>&1; then
                echo "FAIL"
                echo "[-] kubectl не найден. Установите kubectl."
                exit 1
        fi
        echo "OK"

        printf "[+] Checking cluster connectivity... "
        if ! kubectl get --raw='/readyz' > /dev/null 2>&1; then
                echo "FAIL"
                echo "[-] Кластер недоступен. Проверьте minikube status и kubeconfig."
                exit 1
        fi
        echo "OK"

        echo "[+] Nodes summary:"
        kubectl get nodes --no-headers | awk '{ printf "  - %s: %s (%s) [%s]\n", $1, $2, $5, $3 }'

        local pods
        pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.terminated.reason}{"\t"}{.status.containerStatuses[*].restartCount}{"\n"}{end}')

        echo "[+] Pods summary:"
        if [[ -z "$pods" ]]; then
                echo "  Pods not found"
        else
                printf '%s\n' "$pods" | awk -F'\t' '
        {
                status = $3
                n = split($4, r, " ")
                for (i = 1; i <= n; i++) if (r[i] != "") { status = r[i]; break }
                total++
                if (status == "Running") running++
                else if (status == "Pending") pending++
                else if (status == "CrashLoopBackOff") crash++
                else if (status == "Error" || status == "Failed") error++
                else if (status != "Succeeded" && status != "Completed") {
                        other++
                }
                if (status != "Running" && status != "Succeeded" && status != "Completed")
                        bad[++b] = sprintf("  - %s/%s (%s)", $1, $2, status)
                }
                END {
                        printf "  Total: %d | Running: %d | Pending: %d | CrashLoopBackOff: %d | Error: %d | Other: %d\n", total, running, pending, crash, error, other
                if (b > 0) {
                        print "  Failing pods:"
                for (i = 1; i <= b; i++) print "  " bad[i]
                }
        }'
        fi
        echo "[+] Pods with restarts (>0):"
        local restarts=""
        if [[ -n "$pods" ]]; then
                restarts=$(printf '%s\n' "$pods" | awk -F'\t' '{
                n = split($5, c, " "); s = 0
                for (i = 1; i <= n; i++) s += c[i]
                if (s > 0) printf "  - %s/%s (Restarts: %d)\n", $1, $2, s
        }')
        fi
        echo "${restarts:-  none}"
        echo "[+] Services:"
        local svcs
         svcs=$(kubectl get svc "${NS_ARGS[@]}" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,IP:.spec.clusterIP,PORTS:.spec.ports[*].port' 2>/dev/null \
        | awk '{printf "  - %s/%s: %s %s (ports: %s)\n", $1, $2, $3, $4, $5}')
        echo "${svcs:-  none}"

         echo "[+] Node resource usage:"
        local top
         if top=$(kubectl top nodes --no-headers 2>/dev/null) && [[ -n "$top" ]]; then
                printf '%s\n' "$top" | awk '{printf "  - %s: CPU %s (%s), MEM %s (%s)\n", $1, $2, $3, $4, $5}'
        else
                echo "  metrics-server не установлен или недоступен — пропуск"
        fi
}

if $SAVE; then
        FILE="cluster_report_$(date +%Y%m%d_%H%M).txt"
        report | tee "$FILE"
        echo "[+] Report saved to: $FILE"
else
        report
fi