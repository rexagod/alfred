#!/usr/bin/env bash
# shellcheck enable=require-variable-braces

# -e: Exit immediately if a pipeline, a list, or a compound command, exits with a non-zero status.
# -E: If any command in a pipeline errors, the entire pipeline exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: If any command in a pipeline fails, the entire pipeline fails.
set -exEuo pipefail

# TODO:
# - Allow server-side configurations for debugger.
#   - error layer=debugger could not create config directory: mkdir /.config: permission denied

# ASSUMPTIONS (in increasing order of convenience):
#   Image is not distro-less.
#   - `kubectl cp` requires `tar` binary on the target pod (refer https://kubernetes.io/docs/reference/kubectl/cheatsheet/#copy-files-and-directories-to-and-from-containers).
#   Target binary was compiled with debugging capabilities (-gcflags="all=-N -l").
#   Target container has an exposed port, for debugging.

# Initialize colors.
RED="$(tput setaf 1)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
NC="$(tput sgr0)" # No Color.

# Initialize levels.
INFO="${BLUE}INFO${NC}"
WARN="${YELLOW}WARN${NC}"
ERR="${RED}ERROR${NC}"

# Input parameters as long args.
while [[ $# -gt 0 ]]; do
  key="$1"

  case ${key} in
    -n|--namespace)
      NAMESPACE="$2"
      shift # past argument
      shift # past value
      ;;
    -p|--pod)
      POD="$2"
      shift # past argument
      shift # past value
      ;;
    -c|--container)
      CONTAINER="$2"
      shift # past argument
      shift # past value
      ;;
    -a|--target-port)
      TARGET_PORT="$2"
      shift # past argument
      shift # past value
      ;;
    -b|--port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    -x|--proc)
      PROC="$2"
      shift # past argument
      shift # past value
      ;;
    -B|--bypass-entrypoint-check)
      BYPASS_ENTRYPOINT_CHECK="$2"
      shift # past argument
      shift # past value
      ;;
    *)    # unknown option
      shift # past argument
      ;;
  esac
done

# Exit if any parameter is missing.
if [ -z "${NAMESPACE}" ] || [ -z "${POD}" ] || [ -z "${CONTAINER}" ] || [ -z "${TARGET_PORT}" ] || [ -z "${PORT}" ] || [ -z "${PROC}" ]; then
  echo "${INFO} usage: $0 -n|--namespace -p|--pod -c|--container -a|--target-port -b|--port -x|--proc [-B|--bypass-entrypoint-check]"
  exit 1
fi

# Check if kubectl exists in PATH.
if ! command -v kubectl > /dev/null 2>&1; then
  echo "${ERR} kubectl not found in PATH."
  exit 1
fi

# Install kubectl if not installed.
if ! kubectl version --client > /dev/null 2>&1; then
  # Ask if the user wants to install kubectl.
  echo "${INFO} kubectl not found in PATH. Install kubectl? (Y/n)"
  read -r answer
  if [ "${answer}" == "n" ]; then
    exit 1
  else
    # Install kubectl.
    echo "${INFO} installing kubectl"
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256" && \
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    NO_SUDO_BIN="${HOME}/.local/bin"
    chmod +x kubectl
    mkdir -p "${NO_SUDO_BIN}"
    mv ./kubectl ~/.local/bin/kubectl
    echo "${INFO} kubectl installed"
    # check if ~/.local/bin is in $PATH.
    if ! echo $PATH | grep -q "^$HOME/.local/bin$"; then
      echo "${INFO} run the command below to add it to your PATH"
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
  fi
fi

# Check if GOBIN exists.
if [ -z "${GOBIN}" ]; then
  echo "${ERR} GOBIN not set."
  exit 1
fi

# Check if dlv exists.
if [ ! -f "${GOBIN}/dlv" ]; then
  echo "${WARN} dlv binary not found in GOBIN."
  # Ask user if they want to install dlv.
  echo "${INFO} Would you like to install Delve? (Y/n)"
  read -r answer
  if [ "${answer}" == "n" ]; then
    exit 1
  else
    echo "${INFO} installing Delve"
    go get -u github.com/go-delve/delve/cmd/dlv
  fi
fi

# Check if $GOBIN is in $PATH (i.e., is dlv globally available?).
if ! echo "${PATH}" | grep -q "${GOBIN}"; then
  echo "${ERR} GOBIN not in PATH."
  exit 1
fi

# Individual checks for granular errors.
# Check if namespace exists.
if ! kubectl get namespace "${NAMESPACE}" > /dev/null 2>&1; then
  echo "${ERR} ${NAMESPACE} does not exist"
  exit 1
fi

# Check if pod exists inside the given namespace.
if ! kubectl get pod -n "${NAMESPACE}" "${POD}" > /dev/null 2>&1; then
  echo "${ERR} ${NAMESPACE}/${POD} does not exist"
  exit 1
fi

# Check if container exists in the given pod.
if ! kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].name}' > /dev/null 2>&1; then
  echo "${ERR} ${POD}:${CONTAINER} does not exist"
  exit 1
fi

# Check if port is exposed in the given pod.
if ! kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].ports[?(@.containerPort == '"${TARGET_PORT}"')].containerPort}' > /dev/null 2>&1; then
  echo "${ERR} ${POD}:${CONTAINER} does not have ${TARGET_PORT} exposed"
  exit 1
fi

# Check if the container's binary is same as the given proc.
if ! kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].command}' | grep -wq "${PROC}"; then
  echo "${WARN} ${POD}:${CONTAINER} does not have ${PROC} binary as entrypoint"
  # shellcheck disable=SC2091
  $(${BYPASS_ENTRYPOINT_CHECK}) || exit 1
fi

echo "${INFO} injecting debugger in ${BLUE}${NAMESPACE}/${POD}:${CONTAINER}::${TARGET_PORT}${NC}"

DEBUGGER_BINARY="dlv"
DEBUGGER_REMOTE_PATH="/tmp/dlv"
DEBUGGER_LOCAL_PATH="${GOBIN}/dlv"

# Copy delve into the target container.
cp "${DEBUGGER_LOCAL_PATH}" /tmp/
kubectl cp "${DEBUGGER_REMOTE_PATH}" "${NAMESPACE}"/"${POD}":/tmp -c "${CONTAINER}"

# Get entrypoint (or cmd) process pid (will be 1 usually, unless target invokes multiple binaries (for eg., through `kubectl exec`)).
ENTRYPOINT_PID="$(kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${PROC}" | awk 'NR==2{print $2}')"

# Exit if command exited with non-zero status.
if [ -z "${ENTRYPOINT_PID}" ]; then
  echo "${ERR} failed to get process pid"
  exit 1
fi

# Check if the delve binary is already running (due to an older crash).
INJECTION=true
if kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${DEBUGGER_BINARY}" &> /dev/null; then
  echo "${WARN} Delve is already running, skipping injection"
  INJECTION=false
else
  # Run delve binary in the pod, attaching it to the running manager process.
  kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- \
    "${DEBUGGER_REMOTE_PATH}" attach "${ENTRYPOINT_PID}" \
      --accept-multiclient --api-version 2 --check-go-version --headless --listen=":${TARGET_PORT}" --only-same-user false &
  INJECTION_PID="$!"
fi

# Port forward pod.
kubectl port-forward "${POD}" -n "${NAMESPACE}" "${TARGET_PORT}:${PORT}"

# Get debugger process pid.
DELVE_PID="$(kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${DEBUGGER_BINARY}" | awk 'NR==2{print $2}')"

# Cleanup.
# Kill injection and Delve processes on local and target container respectively, when the script is interrupted or exited.
# shellcheck disable=SC2064
# shellcheck disable=SC2091
$(${INJECTION}) && \
trap "\
  echo && \
  kubectl exec -it ${POD} -n ${NAMESPACE} -c ${CONTAINER} -- rm ${DEBUGGER_REMOTE_PATH} && \
  kill -9 ${INJECTION_PID} && \
  kubectl exec -it ${POD} -n ${NAMESPACE} -c ${CONTAINER} -- kill -9 ${DELVE_PID} > /dev/null" \
  SIGINT SIGTERM EXIT
