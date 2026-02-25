#!/usr/bin/env bash
set -euo pipefail

ANN_KEY='descheduler.alpha.kubernetes.io/evict'
ANN_VAL='true'

# Lista todas as VMs (KubeVirt) em todas as namespaces e aplica o patch na spec.template.metadata.annotations
oc get vm -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
| while IFS=$'\t' read -r ns name; do
    [[ -z "${ns}" || -z "${name}" ]] && continue

    echo "Patching vm/${name} in ns/${ns} ..."
    oc -n "${ns}" patch vm "${name}" --type=merge \
      -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"${ANN_KEY}\":\"${ANN_VAL}\"}}}}}"
  done
