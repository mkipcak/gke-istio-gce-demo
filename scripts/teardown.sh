#! /usr/bin/env bash

# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# properties file
# shellcheck source=properties.env
source "${ROOT}/properties.env"

ISTIO_SHARED_DIR="${ROOT}/gke-istio-shared"
ISTIO_DIR="${ROOT}/istio-${ISTIO_VERSION}"

# functions to check existence of resources
# shellcheck source=gke-istio-shared/verify-functions.sh
source "${ISTIO_SHARED_DIR}/verify-functions.sh"

# Delete all created Istio and Kubernetes resources
if directory_exists "${ISTIO_DIR}"; then
  kubectl delete -f <("${ISTIO_DIR}/bin/istioctl" kube-inject -f \
    "${ISTIO_DIR}/samples/bookinfo/platform/kube/bookinfo-ratings-v2-mysql-vm.yaml") \
    --ignore-not-found="true"
  kubectl delete -f <("${ISTIO_DIR}/bin/istioctl" kube-inject -f \
    "${ISTIO_DIR}/samples/bookinfo/platform/kube/bookinfo.yaml") \
    --ignore-not-found="true"
fi

kubectl delete -f <("${ISTIO_DIR}/bin/istioctl" kube-inject -f \
  "${ISTIO_DIR}/install/kubernetes/mesh-expansion.yaml") --ignore-not-found="true"

kubectl delete -f <("${ISTIO_DIR}/bin/istioctl" kube-inject -f \
  "${ISTIO_DIR}/install/kubernetes/istio-demo.yaml") --ignore-not-found="true"

kubectl delete clusterrolebinding cluster-admin-binding --ignore-not-found="true"

# Wait for Kubernetes resources to be deleted before deleting the cluster
# Also, filter out the resources to what would specifically be created for
# the GKE cluster
until [[ $(gcloud --project="${PROJECT}" compute target-pools list \
              --format="value(name)" \
              --filter="instances[]:gke-${CLUSTER_NAME}") == "" ]]; do
  echo "Waiting for cluster to become ready for destruction..."
  sleep 10
done

until [[ $(gcloud --project="${PROJECT}" compute forwarding-rules list --format yaml \
              --filter "description:istio-system OR description:kube-system/dns-ilb") == "" ]]; do
  echo "Waiting for cluster to become ready for destruction..."
  sleep 10
done

until [[ $(gcloud --project="${PROJECT}" compute firewall-rules list \
             --filter "name:k8s AND targetTags.list():gke-${CLUSTER_NAME}" \
             --format "value(name)") == "" ]]; do
  echo "Waiting for cluster to become ready for destruction..."
  sleep 10
done

#### delete mesh expansion files
if directory_exists "${ISTIO_DIR}" ; then
  for FILE in "${ISTIO_DIR}/cluster.env" "${ISTIO_DIR}/cluster.env.original" "${ISTIO_DIR}/kubedns" "${ISTIO_DIR}/root-cert.pem" "istio=mixer"
  do
    if file_exists "${FILE}" ; then
      echo ""
      echo " deleting ${FILE} file"
      echo ""
      rm "${FILE}"
      echo ""
      echo ""
    fi
  done
fi

#### delete gce instance
if instance_exists "${PROJECT}" "${GCE_VM}" ; then
  echo ""
  echo " deleting istio gce instance"
  echo ""
  gcloud compute instances delete "${GCE_VM}" --project "${PROJECT}" --zone "${ZONE}" --quiet
  echo ""
  echo ""
fi

# Delete kubernetes resources
if cluster_exists "${PROJECT}" "${CLUSTER_NAME}" ; then
  # delete istio cluster
  echo ""
  echo " deleting istio cluster"
  echo ""
  gcloud container clusters delete "${CLUSTER_NAME}" --project "${PROJECT}" --zone "${ZONE}" --quiet
  echo ""
  echo ""
fi

# Delete any firewalls created by the cluster for node communication
if firewall_exists "${PROJECT}" "${CLUSTER_NAME}" ; then
  echo ""
  echo " deleting cluster firewalls"
  echo ""
  while IFS= read -r RESULT
  do
      gcloud compute --project "${PROJECT}" firewall-rules delete "${RESULT}" --quiet
  done < <(gcloud compute firewall-rules list --project "${PROJECT}" --filter "name=${CLUSTER_NAME}" --format "value(name)")
  echo ""
  echo ""
fi

# Delete any firewalls created by GKE to allow for load balancer communication
if firewall_exists "${PROJECT}" "k8s" ; then
  echo ""
  echo " deleting k8s firewalls"
  echo ""
  while IFS= read -r RESULT
  do
      gcloud compute --project "${PROJECT}" firewall-rules delete "${RESULT}" --quiet
  done < <(gcloud compute firewall-rules list --project "${PROJECT}" | grep "k8s" | awk '{print $1}')
  echo "Delete firewall allowing MySQL traffic"
  echo ""
  echo ""
fi

if firewall_exists "${PROJECT}" "allow-mysql"; then
  gcloud compute --project "${PROJECT}" firewall-rules delete allow-mysql --quiet
fi

if firewall_exists "${PROJECT}" "allow-ssh-istio-vm"; then
  gcloud compute --project "${PROJECT}" firewall-rules delete allow-ssh-istio-vm --quiet
fi

# Delete the network created for the cluster
if network_exists "${PROJECT}" "${NETWORK_NAME}" ; then
  gcloud compute --project "${PROJECT}" networks delete "${NETWORK_NAME}" --quiet
fi

# Remove Istio components
if directory_exists "${ISTIO_DIR}" ; then
  rm -rf "${ISTIO_DIR}"
fi
