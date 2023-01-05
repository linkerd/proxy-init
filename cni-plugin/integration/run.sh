#!/usr/bin/env bash

set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

# Run kubectl with the correct context.
function k() {
  if [ -n "${TEST_CTX:-}" ]; then
    kubectl --context="$TEST_CTX" "$@"
  else
    kubectl "$@"
  fi
}

function create_test_lab() {
    echo '# Creating the test lab...'
    k create ns cni-plugin-test
    k create serviceaccount linkerd-cni
    # TODO(stevej): how can we parameterize this manifest with `version` so we
    # can enable a testing matrix?
    k create -f manifests/linkerd-cni.yaml
}

function cleanup() {
    echo '# Cleaning up...'
    #k delete -f manifests/cni-plugin-lab.yaml
    # TODO(stevej): how do we parameterize the linkerd-cni
    # container image? we'd like to use releases as well as test
    k delete -f manifests/linkerd-cni.yaml
    k delete serviceaccount linkerd-cni
    k delete ns cni-plugin-test
}

trap cleanup EXIT

# Get the IP of a test pod.
function kip() {
    local name=$1
    k wait pod "$name" --namespace=cni-plugin-test \
        --for=condition=ready --timeout=1m \
        >/dev/null

    k get pod "$name" --namespace=cni-plugin-test \
        --template='{{.status.podIP}}'
}

if k get ns/cni-plugin-test >/dev/null 2>&1 ; then
  echo 'ns/cni-plugin-test already exists' >&2
  exit 1
fi

create_test_lab
# Wait for linkerd-cni daemonset to complete
if ! k rollout status --timeout=30s daemonset/linkerd-cni -n linkerd-cni; then
  echo "!! linkerd-cni didn't rollout properly, check logs";
  exit $?
fi

#TODO(stevej): using the cni-plugin-lab as a manifest lets me exercise
#the linkerd-network-validator but makes seeing the test output impossible.
#
#echo "# linkerd-cni is running, starting first cni-plugin test..."
#k create -f manifests/cni-plugin-lab.yaml
# Wait for cni-plugin-lab deployment to complete
#if ! k rollout status --timeout=30s deployment/cni-plugin-tester-deployment -n cni-plugin-test; then
#    echo "!! cni-plugin-tester-deployment failed, check logs"
#    exit $?
#fi

# This needs to use the name linkerd-proxy so that linkerd-cni will run.
echo '# Running tester...'
k run linkerd-proxy \
        --attach \
        --image="test.l5d.io/linkerd/cni-plugin-tester:test" \
        --image-pull-policy=Never \
        --namespace=cni-plugin-test \
        --restart=Never \
        -- \
        go test -v ./cni-plugin/integration/... -integration-tests

