#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"

if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, abort." && exit 1
fi

if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]] && [[ ! -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  echo "Lack of VPC info, abort." && exit 1
fi


#####################################
##############Initialize#############
#####################################

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

workdir=`mktemp -d`

curl -L -o ${workdir}/fcos-stable.json https://builds.coreos.fedoraproject.org/streams/stable.json
IMAGE_NAME=$(jq -r .architectures.x86_64.images.gcp.name < ${workdir}/fcos-stable.json)
if [ -z "${IMAGE_NAME}" ]; then
  echo "Missing IMAGE in region: ${REGION}" 1>&2
  exit 1
fi
IMAGE_PROJECT=$(jq -r .architectures.x86_64.images.gcp.project < ${workdir}/fcos-stable.json)
IMAGE_RELEASE=$(jq -r .architectures.x86_64.images.gcp.release < ${workdir}/fcos-stable.json)
echo "Using FCOS ${IMAGE_RELEASE} IMAGE: ${IMAGE_NAME}"


#####################################
###############Log In################
#####################################

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

REGION="${LEASED_RESOURCE}"
echo "Using region: ${REGION}"

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  NETWORK=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.network')
  CONTROL_PLANE_SUBNET=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.controlPlaneSubnet')
fi
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  echo "Could not find VPC network and control-plane subnet" && exit 1
fi
ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)
MACHINE_TYPE="n2-standard-1"

#####################################
##########Create Bastion#############
#####################################

# we need to be able to tear down the proxy even if install fails
# cannot rely on presence of ${SHARED_DIR}/metadata.json
echo "${REGION}" >> "${SHARED_DIR}/proxyregion"

bastion_name="${CLUSTER_NAME}-bastion"
gcloud compute instances create "${bastion_name}" \
  --image=${IMAGE_NAME} \
  --image-project=${IMAGE_PROJECT} \
  --boot-disk-size=200GB \
  --metadata-from-file=user-data=${bastion_ignition_file} \
  --machine-type=${MACHINE_TYPE} \
  --network=${NETWORK} \
  --subnet=${CONTROL_PLANE_SUBNET} \
  --zone=${ZONE_0} \
  --tags="${bastion_name}"

echo "Created bastion instance"
echo "Waiting for the proxy service starting running..." && sleep 60s

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  project_option="--project=${HOST_PROJECT}"
else
  project_option=""
fi
gcloud ${project_option} compute firewall-rules create "${bastion_name}-ingress-allow" \
  --network ${NETWORK} \
  --allow tcp:22,tcp:3128,tcp:3129,tcp:5000,tcp:6001,tcp:6002,tcp:8080 \
  --target-tags="${bastion_name}"
cat > "${SHARED_DIR}/bastion-destroy.sh" << EOF
gcloud compute instances delete -q "${bastion_name}" --zone=${ZONE_0}
gcloud ${project_option} compute firewall-rules delete -q "${bastion_name}-ingress-allow"
EOF

#####################################
#########Save Bastion Info###########
#####################################
echo "Instance ${bastion_name}"
# to allow log collection during gather:
# append to proxy instance ID to "${SHARED_DIR}/gcp-instance-ids.txt"
echo "${bastion_name}" >> "${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=${bastion_name}" \
  --zones "${ZONE_0}" --format json > "${workdir}/${bastion_name}.json"
bastion_private_ip="$(jq -r '.[].networkInterfaces[0].networkIP' ${workdir}/${bastion_name}.json)"
bastion_public_ip="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' ${workdir}/${bastion_name}.json)"

if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

src_proxy_creds_file="/var/run/vault/proxy/proxy_creds"
proxy_credential=$(cat "${src_proxy_creds_file}")
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" >> "${SHARED_DIR}/proxyip"

#####################################
####Register mirror registry DNS#####
#####################################
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
  BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
  BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"

  echo "Configuring public DNS for the mirror registry..."
  gcloud dns record-sets create "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." \
  --rrdatas="${bastion_public_ip}" --type=A --ttl=60 --zone="${BASE_DOMAIN_ZONE_NAME}"

  echo "Configuring private DNS for the mirror registry..."
  gcloud dns managed-zones create "${CLUSTER_NAME}-mirror-registry-private-zone" \
  --description "Private zone for the mirror registry." \
  --dns-name "mirror-registry.${BASE_DOMAIN}." --visibility "private" --networks "${NETWORK}"
  gcloud dns record-sets create "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." \
  --rrdatas="${bastion_private_ip}" --type=A --ttl=60 --zone="${CLUSTER_NAME}-mirror-registry-private-zone"

  cat > "${SHARED_DIR}/mirror-dns-destroy.sh" << EOF
  gcloud dns record-sets delete -q "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." --type=A --zone="${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets delete -q "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." --type=A --zone="${CLUSTER_NAME}-mirror-registry-private-zone"
  gcloud dns managed-zones delete -q "${CLUSTER_NAME}-mirror-registry-private-zone"
EOF

  echo "Waiting for ${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN} taking effect..." && sleep 120s

  MIRROR_REGISTRY_URL="${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}:5000"
  echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"
fi

#####################################
##############Clean Up###############
#####################################
rm -rf "${workdir}"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
