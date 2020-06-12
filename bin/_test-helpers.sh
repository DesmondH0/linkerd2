#!/bin/bash

# Override CI's `set -e` default, so we can catch errors manually and display
# proper messages
set +e

##### Test setup helpers #####

export test_names=(upgrade helm helm-upgrade uninstall deep external-issuer)

handle_input() {
  export images=""
  export images_host=""
  export test_name=""
  export skip_kind_create=""

  while :
  do
    case $1 in
      -h|--help)
        echo "Run Linkerd integration tests."
        echo ""
        echo "Optionally specify one of the following tests: [${test_names[*]}]"
        echo ""
        echo "Usage:"
        echo "    ${0##*/} [--images] [--images-host ssh://linkerd-docker] [--name test-name] [--skip-kind-create] /path/to/linkerd"
        echo ""
        echo "Examples:"
        echo ""
        echo "    # Run all tests in isolated clusters"
        echo "    ${0##*/} /path/to/linkerd"
        echo ""
        echo "    # Run single test in isolated clusters"
        echo "    ${0##*/} --name test-name /path/to/linkerd"
        echo ""
        echo "    # Skip KinD cluster creation and run all tests in default cluster context"
        echo "    ${0##*/} --skip-kind-create /path/to/linkerd"
        echo ""
        echo "    # Load images from tar files located under the 'image-archives' directory"
        echo "    # Note: This is primarly for CI"
        echo "    ${0##*/} --images /path/to/linkerd"
        echo ""
        echo "    # Retrieve images from a remote docker instance and then load them into KinD"
        echo "    # Note: This is primarly for CI"
        echo "    ${0##*/} --images --images-host ssh://linkerd-docker /path/to/linkerd"
        echo "Available Commands:"
        echo "    --name: the argument to this option is the specific test to run"
        echo "    --skip-kind-create: skip KinD cluster creation step and run tests in an existing cluster."
        echo "    --images: (Primarily for CI) use 'kind load image-archive' to load the images from local .tar files in the current directory."
        echo "    --images-host: (Primarily for CI) the argument to this option is used as the remote docker instance from which images are first retrieved (using 'docker save') to be then loaded into KinD. This command requires --images."
        exit 0
        ;;
      --images)
        images=1
        ;;
      --images-host)
        images_host=$2
        if [ -z "$images_host" ]; then
          echo "Error: the argument for --images-host was not specified"
          exit 1
        fi
        shift
        ;;
      --name)
        test_name=$2
        if [ -z "$test_name" ]; then
          echo "Error: the argument for --name was not specified"
          exit 1
        fi
        shift
        ;;
      --skip-kind-create)
        skip_kind_create=1
        ;;
      *)
        break
    esac
    shift
  done

  if [ "$images_host" ] && [ -z "$images" ]; then
    echo "Error: --images-host needs to be used with --images" >&2
    exit 1
  fi

  export linkerd_path="$1"
  if [ -z "$linkerd_path" ]; then
    echo "Error: path to linkerd binary is required"
    echo "Help:"
    echo "     ${0##*/} -h|--help"
    echo "Basic usage:"
    echo "     ${0##*/} /path/to/linkerd"
    exit 64
  fi
}

test_setup() {
  bindir=$( cd "${BASH_SOURCE[0]%/*}" && pwd )
  export bindir

  export test_directory="$bindir"/../test

  check_linkerd_binary
}

check_linkerd_binary(){
  printf 'Checking the linkerd binary...'
  if [[ "$linkerd_path" != /* ]]; then
    printf '\n[%s] is not an absolute path\n' "$linkerd_path"
    exit 1
  fi
  if [ ! -x "$linkerd_path" ]; then
    printf '\n[%s] does not exist or is not executable\n' "$linkerd_path"
    exit 1
  fi
  exit_code=0
  "$linkerd_path" version --client > /dev/null 2>&1
  exit_on_err 'error running linkerd version command'
  printf '[ok]\n'
}

##### Cluster helpers #####

create_cluster() {
  local name=$1
  local config=$2
  "$bindir"/kind create cluster --name "$name" --config "$test_directory"/configs/"$config".yaml --wait 300s 2>&1
  exit_on_err 'error creating KinD cluster'
  export context="kind-$name"
}

check_cluster() {
  check_if_k8s_reachable
  check_if_l5d_exists
}

delete_cluster() {
  local name=$1
  "$bindir"/kind delete cluster --name "$name" 2>&1
}

cleanup_cluster() {
  "$bindir"/test-cleanup "$context" > /dev/null 2>&1
  exit_on_err 'error removing existing Linkerd resources'
}

check_if_k8s_reachable(){
  printf 'Checking if there is a Kubernetes cluster available...'
  exit_code=0
  kubectl --context="$context" --request-timeout=5s get ns > /dev/null 2>&1
  exit_on_err 'error connecting to Kubernetes cluster'
  printf '[ok]\n'
}

check_if_l5d_exists() {
  printf 'Checking if Linkerd resources exist on cluster...'
  local resources
  resources=$(kubectl --context="$context" get all,clusterrole,clusterrolebinding,mutatingwebhookconfigurations,validatingwebhookconfigurations,psp,crd -l linkerd.io/control-plane-ns --all-namespaces -oname)
  if [ -n "$resources" ]; then
    printf '
Linkerd resources exist on cluster:
\n%s\n
Help:
    Run: [%s/test-cleanup]' "$resources" "$bindir"
    exit 1
  fi
  printf '[ok]\n'
}

##### Test runner helpers #####

start_test() {
  name=$1
  config=$2

  test_setup
  if [ -z "$skip_kind_create" ]; then
    create_cluster "$name" "$config"
    "$bindir"/kind-load ${images:+'--images'} ${images_host:+'--images-host' "$images_host"} "$name"
  fi
  check_cluster
  run_"$name"_test
  if [ -z "$skip_kind_create" ]; then
    delete_cluster "$name"
  else
    cleanup_cluster
  fi
}

get_test_config() {
  local name=$1
  config=""
  case $name in
    cluster-domain)
      config="cluster-domain"
      ;;
    *)
      config="default"
      ;;
  esac
  echo "$config"
}

run_test(){
  local filename=$1
  shift

  printf 'Test script: [%s] Params: [%s]\n' "${filename##*/}" "$*"
  # Exit on failure here
  GO111MODULE=on go test --failfast --mod=readonly "$filename" --linkerd="$linkerd_path" --k8s-context="$context" --integration-tests "$@" || exit 1
}

# Returns the latest stable verson
latest_stable() {
  curl -s https://versioncheck.linkerd.io/version.json | grep -o "stable-[0-9]*.[0-9]*.[0-9]*"
}

# Install the latest stable release.
install_stable() {
  tmp=$(mktemp -d -t l5dbin.XXX)

  curl -s https://run.linkerd.io/install | HOME=$tmp sh > /dev/null 2>&1

  local linkerd_path=$tmp/.linkerd2/bin/linkerd
  local test_app_namespace='upgrade-test'

  (
    set -x
    "$linkerd_path" install | kubectl --context="$context" apply -f - 2>&1
  )
  exit_on_err 'install_stable() - installing stable failed'

  (
    set -x
    "$linkerd_path" check 2>&1
  )
  exit_on_err 'install_stable() - linkerd check failed'

  #Now we need to install the app that will be used to verify that upgrade does not break anything
  kubectl --context="$context" create namespace "$test_app_namespace" > /dev/null 2>&1
  kubectl --context="$context" label namespaces "$test_app_namespace" 'linkerd.io/is-test-data-plane'='true' > /dev/null 2>&1
  (
    set -x
    "$linkerd_path" inject "$test_directory/testdata/upgrade_test.yaml" | kubectl --context="$context" apply --namespace="$test_app_namespace" -f - 2>&1
  )
  exit_on_err 'install_stable() - linkerd inject failed'
}

# Run the upgrade test by upgrading the most-recent stable release to the HEAD
# of this branch.
run_upgrade_test() {
  local stable_version
  stable_version=$(latest_stable)

  install_stable
  run_test "$test_directory/install_test.go" --upgrade-from-version="$stable_version"
}

setup_helm() {
  export helm_path="$bindir"/helm
  helm_chart="$( cd "$bindir"/.. && pwd )"/charts/linkerd2
  export helm_chart
  export helm_release_name='helm-test'
  "$bindir"/helm-build
  "$helm_path" --kube-context="$context" repo add linkerd https://helm.linkerd.io/stable
  exit_on_err 'error setting up Helm'
}

run_helm_test() {
  setup_helm
  run_test "$test_directory/install_test.go" --helm-path="$helm_path" --helm-chart="$helm_chart" \
  --helm-release="$helm_release_name"
}

run_helm-upgrade_test() {
  local stable_version
  stable_version=$(latest_stable)

  setup_helm
  run_test "$test_directory/install_test.go" --helm-path="$helm_path" --helm-chart="$helm_chart" \
  --helm-stable-chart='linkerd/linkerd2' --helm-release="$helm_release_name" --upgrade-helm-from-version="$stable_version"
}

run_uninstall_test() {
  run_test "$test_directory/uninstall/uninstall_test.go" --uninstall=true
}

run_deep_test() {
  run_test "$test_directory/install_test.go"
  while IFS= read -r line; do tests+=("$line"); done <<< "$(go list "$test_directory"/.../...)"
  run_test "${tests[@]}"
}

run_external-issuer_test() {
  run_test "$test_directory/install_test.go" --external-issuer=true
  run_test "$test_directory/externalissuer/external_issuer_test.go" --external-issuer=true
}

run_cluster-domain_test() {
  run_test "$test_directory/install_test.go" --cluster-domain='custom.domain'
}

# exit_on_err should be called right after a command to check the result status
# and eventually generate a Github error annotation. Do not use after calls to
# `go test` as that generates its own annotations. Note this should be called
# outside subshells in order for the script to terminate.
exit_on_err() {
  exit_code=$?
  if [ $exit_code -ne 0 ]; then
    export GH_ANNOTATION=${GH_ANNOTATION:-}
    if [ -n "$GH_ANNOTATION" ]; then
      printf '::error::%s\n' "$1"
    else
      printf '\n=== FAIL: %s\n' "$1"
    fi
    exit $exit_code
  fi
}
