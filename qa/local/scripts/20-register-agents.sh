#!/bin/zsh

# export KUBECONFIG="$PWD/default_config/upstream.yaml"
# kubectl config use-context upstream

count=0

for cfg in ./default_config/downstream-*-direct.yaml; do
    count=$(( count + 1 ))

    value=$(cat "$cfg")

    clustername=cluster-$count
    kubectl create secret generic -n fleet-default kcfg-$clustername --from-literal=value="$value"

    kubectl apply -n fleet-default -f - <<EOF
apiVersion: "fleet.cattle.io/v1alpha1"
kind: Cluster
metadata:
  name: $clustername
  namespace: fleet-default
  labels:
    name: $cluster
    cluster: "$count"
spec:
  kubeConfigSecret: kcfg-$clustername
EOF

done

