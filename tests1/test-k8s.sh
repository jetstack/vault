#!/bin/bash

set -e
# set -x

. vault.env

COMPONENTS="etcd-k8s etcd-overlay k8s"
BASE_PATH="${CLUSTER_ID}/pki"

# create a CA per component (not intermediate)
for component in ${COMPONENTS}; do
    path="${BASE_PATH}/${component}"
    description="Kubernetes ${CLUSTER_ID}/${component} CA"
    vault mount -path "${path}" -description "${description}" pki
    vault mount-tune -max-lease-ttl=87600h "${path}"
    vault write "${path}/root/generate/internal" \
        common_name="${description}" \
        ttl=87600h # 10 years

    # if it's a etcd ca populate only a single role
    if [[ "${component}" == etcd-* ]]; then
        vault write "${path}/roles/client" \
            allow_any_name=true \
            max_ttl="720h" \
            server_flag=true \
            client_flag=true
        vault write "${path}/roles/server" \
            allow_any_name=true \
            max_ttl="720h" \
            server_flag=false \
            client_flag=true
    fi

    # if it's k8s
    if [[ "${component}" == "k8s" ]]; then
        for role in admin kubelet kube-scheduler kube-controller-manager kube-proxy; do
            vault write "${path}/roles/${role}" \
                allowed_domains="${role}" \
                allow_bare_domains=true \
                allow_localhost=false \
                allow_subdomains=false \
                allow_ip_sans=false \
                server_flag=false \
                client_flag=true \
                max_ttl="720h"
        done
        vault write "${path}/roles/kube-apiserver" \
            allow_localhost=true \
            allow_any_name=true \
            allow_bare_domains=true \
            allow_ip_sans=true \
            server_flag=true \
            client_flag=false \
            max_ttl="720h"
    fi
done

# Generic secrets mount
secrets_path="${CLUSTER_ID}/secrets"
vault mount -path "${secrets_path}" -description="Kubernetes ${CLUSTER_ID} secrets" generic

# Generate a key for the service accounts
openssl genrsa 4096 | vault write "${secrets_path}/service-accounts" key=-

# Generate policies per node role
for role in master worker etcd; do
    policy_name="${CLUSTER_ID}/${role}"
    policy=""
    #    vault policy-write "${policy_name}" - <<EOF
    if [[ "${role}" == "master" ]] || [[ "${role}" == "worker" ]]; then
        for cert_role in k8s/sign/kubelet k8s/sign/kube-proxy etcd-overlay/sign/client; do
            policy="${policy}
path \"${BASE_PATH}/${cert_role}\" {
    capabilities = [\"create\",\"read\",\"update\"]
}
"
        done
    fi

    if [[ "${role}" == "master" ]]; then
        for cert_role in k8s/sign/kube-apiserver k8s/sign/kube-scheduler k8s/sign/kube-controller-manager etcd-k8s/sign/client; do
            policy="${policy}
path \"${BASE_PATH}/${cert_role}\" {
    capabilities = [\"create\",\"read\",\"update\"]
}
"
        done
        policy="${policy}
path \"${secrets_path}/service-accounts\" {
    capabilities = [\"read\"]
}
"
    fi

    if [[ "${role}" == "etcd" ]]; then
        for cert_role in etcd-k8s/sign/server etcd-overlay/sign/server; do
            policy="${policy}
path \"${BASE_PATH}/${cert_role}\" {
    capabilities = [\"create\",\"read\",\"update\"]
}
"
        done
    fi

    # write out new policy
    echo "${policy}" | vault policy-write "${policy_name}" -

    # create token role
    token_role="auth/token/roles/${CLUSTER_ID}-${role}"
    vault write "${token_role}" \
        period="720h" \
        orphan=true \
        allowed_policies="default,${policy_name}" \
        path_suffix="${policy_name}"

    # create token create policy
    vault policy-write "${policy_name}-creator" - <<EOF
path "auth/token/create/${CLUSTER_ID}-${role}" {
    capabilities = ["create","read","update"]
}
EOF

    init_token=unknown
    role_uppercase="$(echo "${role}" | tr '[a-z]' '[A-Z]')"
    eval "init_token=\${VAULT_INIT_TOKEN_${role_uppercase}}"
    vault token-create \
        -id="${init_token}" \
        -display-name="${policy_name}-creator" \
        -orphan \
        -ttl="8760h" \
        -period="8760h" \
        -policy="${policy_name}-creator"

done
