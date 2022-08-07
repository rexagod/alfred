#!/usr/bin/env bash
# shellcheck enable=require-variable-braces
# shellcheck disable=SC2012

# Need to explicitly export this if for env -s cmd, to allow usage of bash exported functions inside cmd.
export SHELL=/bin/bash

# -e: Exit immediately if a pipeline, a list, or a compound command, exits with a non-zero status.
# -E: If any command in a pipeline errors, the entire pipeline exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: If any command in a pipeline fails, the entire pipeline fails.
set -eEo pipefail

# TODO:
# - Allow server-side configurations for debugger.
#   - error layer=debugger could not create config directory: mkdir /.config: permission denied

# ASSUMPTIONS (in increasing order of convenience):
#   Image is not distro-less.
#   - `kubectl cp` requires `tar` binary on the target pod (refer https://kubernetes.io/docs/reference/kubectl/cheatsheet/#copy-files-and-directories-to-and-from-containers).
#   Target binary was compiled with debugging capabilities (-gcflags="all=-N -l").
#   Target container has an exposed port, for debugging.

###############
# LEVEL 3 FNs #
###############

# ___cleanup removes all orphan processes and generated artefacts.
# ___core entails the core logic for re-runs.
function ___core() {
	__inject
	__attach
	__relay
}

# ___cleanup removes all orphan processes and generated artefacts before exiting.
function ___cleanup() {
	DELVE_PID="$(kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${DEBUGGER_BINARY}" | awk 'NR==2{print $2}')"
	echo -e "${INFO} cleaning up"
	kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- rm "${DEBUGGER_REMOTE_PATH}" >/dev/null
	echo "${INFO} killing injection local process with pid: ${INJECTION_PID}"
	kill -9 "${INJECTION_PID}" >/dev/null
	kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- kill -9 "${DELVE_PID}" >/dev/null
}

# ___external_operations entails the build, tag, push, and patch operations.
function ___external_operations() {
	__build_and_push
	__patch
}

# ___recreate_pod kills the existing pod and creates a new one, with the debug image.
function ___recreate_pod() {
	# Delete the existing pod.
	POD="$(__deduce_pod)"
	echo "${INFO} deleting existing pod"
	kubectl delete pod "${POD}" -n "${NAMESPACE}"
	# Wait for the new pod to come up.
	sleep 10s
	# Wait for the container image to be updated.
	echo "${INFO} checking if the pod is in a ready state"
	# Check if the target container is ready in the newer pod.
	while [ "$(kubectl get pod "$(__deduce_pod)" -n "${NAMESPACE}" \
		-o=jsonpath='{.status.containerStatuses[?(@.name == "'"${CONTAINER}"'")].ready}' | tr -d '"')" != "true" ]; do
		sleep 5s
	done
	echo "${INFO} pod is in a ready state, proceeding"
	POD="$(__deduce_pod)"
}

###############
# LEVEL 2 FNs #
###############

# __attach attaches the debugger binary to the target process and start the debugging server.
function __attach() {
	# Check if the target container is running in the target container.
	while true; do
		echo "${INFO} checking if the debugger process is already running in the target container"
		# TODO: See if this is returning proper exit code.
		if kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${DEBUGGER_BINARY}" >/dev/null; then
			echo "${INFO} debugger binary is not running, waiting for it to start"
			sleep 5s
		else
			break
		fi
	done
	# Run delve binary in the pod, attaching it to the running manager process.
	while ! kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- \
		"${DEBUGGER_REMOTE_PATH}" attach "${ENTRYPOINT_PID}" \
		--accept-multiclient \
		--api-version 2 \
		--check-go-version \
		--headless \
		--listen=":${TARGET_PORT}" & do
		#           --only-same-user false &
		if kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${DEBUGGER_BINARY}" >/dev/null; then
			echo "${INFO} Delve is now running"
			break
		fi
		echo "${WARN} Delve is not yet running, waiting for it to start"
		sleep 5
	done
	# We will need this later on to cleanup this background process.
	export INJECTION_PID="$!"
	echo "${INFO} injection process PID: ${INJECTION_PID}"
}

# __build_and_push builds and pushes the debug docker image.
# This image (or container) has a port exposed, and is not distro-less.
function __build_and_push() {
	# Build the debug image using the pre-defined target for this purpose in the repository.
	# Search for EXPOSE keyword in the dockerfile, there is no port exposed if that does not exist.
	POD="$(__deduce_pod)"
	if grep -q "EXPOSE" "${DOCKERFILE}"; then
		echo "${INFO} exposed port found in ${BLUE}${DOCKERFILE}${NC}, building debug image"
	else
		echo -e "${WARN} no ports were exposed in ${BLUE}${DOCKERFILE}${NC}, continuing"
		if [ "$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].ports}')" == "" ]; then
			echo "${ERR} no exposed ports found in the target container, exiting"
			exit 1
		fi
	fi
	DOCKERFILE_DIR="$(dirname "${DOCKERFILE}")"
	cd "${DOCKERFILE_DIR}" || exit 1
	DOMAIN="${DOMAIN:-quay.io}"
	REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-${USER}}"
	DEFAULT_IMAGE="${DOMAIN}/${REGISTRY_NAMESPACE}/${PWD##*/}:debug-$(eval echo ${RANDOM})"
	echo "${INFO} building image: ${DEFAULT_IMAGE}"
	IMAGE="${IMAGE:-${DEFAULT_IMAGE}}"
	docker build -t "${IMAGE}" -f "${DOCKERFILE}" .
	cd - >/dev/null
	docker push "${IMAGE}"
}

# __deduce_pod detect the full pod name from the provide pod prefix.
function __deduce_pod() {
	# Wait for the pod to come up (be consistent).
	sleep 5s
	# Fetch the pod based on a regex pattern.
	# List all pods in the namespace.
	PODS="$(kubectl get pods -n "${NAMESPACE}" -o json | jq -r '.items[].metadata.name')"
	# Find the pod that matches the regex pattern.
	FOUND_POD="$(echo "${PODS}" | grep -E "${POD_PREFIX}")"
	if [ -z "${FOUND_POD}" ]; then
		echo "${ERR} no pod found matching the pattern: ${PATTERN}"
		exit 1
	fi
	echo "${FOUND_POD}"
}

# _inject injects the debugger binary into the target container.
function __inject() {
	# Wait for the pod to come up.
	sleep 10s
	echo "${INFO} injecting debugger in ${BLUE}${NAMESPACE}/${POD}:${CONTAINER}::${TARGET_PORT}${NC}"
	___recreate_pod

	DEBUGGER_BINARY="dlv"
	DEBUGGER_REMOTE_PATH="/tmp/dlv"
	DEBUGGER_LOCAL_PATH="${GOBIN}/dlv"

	# Copy delve into the target container, if it's already not there.
	if kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ls /tmp/dlv &>/dev/null; then
		true
	else
		cp "${DEBUGGER_LOCAL_PATH}" /tmp/
		kubectl cp "${DEBUGGER_REMOTE_PATH}" "${NAMESPACE}"/"${POD}":/tmp -c "${CONTAINER}"
	fi

	# Get entrypoint (or cmd) process pid (will be 1 usually, unless target invokes multiple binaries (for eg., through `kubectl exec`)).
	ENTRYPOINT_PID="$(kubectl exec -it "${POD}" -n "${NAMESPACE}" -c "${CONTAINER}" -- ps -fC "${PROC}" | awk 'NR==2{print $2}')"

	# Exit if command exited with non-zero status.
	if [ -z "${ENTRYPOINT_PID}" ]; then
		echo "${ERR} failed to get process pid"
		exit 1
	fi
}

# __patch patches the CR.
function __patch() {
	___recreate_pod
	# Patch the CR to point to the newer image.
	# Fetch the image that's being used by the CONTAINER.
	OLD_IMAGE="$(kubectl get -n "${NAMESPACE}" pod -o=jsonpath="{.spec.containers[?(@.name==\"${CONTAINER}\")].image}" "${POD}")"
	NEW_IMAGE="${IMAGE}"
	echo "${INFO} image to be replaced: ${OLD_IMAGE}"
	echo "${INFO} image to be injected: ${IMAGE}"
	# Replace the image in the CR with the newer one.
	# Continue if the above command exited with non-zero status.
	if [ "$(KUBE_EDITOR="sed -i s#${OLD_IMAGE}#${NEW_IMAGE}#g" kubectl edit "${KIND}" -n "${NAMESPACE}" "${RESOURCE_NAME}")" == "" ]; then
		echo "${INFO} no changes made to ${BLUE}${KIND}/${RESOURCE_NAME}${NC}"
	else
		echo "${INFO} patched ${BLUE}${KIND}/${RESOURCE_NAME}${NC}"
		___recreate_pod
		echo "${INFO} new pod: ${POD}"
	fi
}

# __relay forwards the debugger connection from the target container.
function __relay() {
	function ___recurse() {
		echo "${INFO} stopping port forwarding"
		if kill -9 $!; then
			true
		else
			echo "${ERR} no port forward process to stop"
		fi
		_watch
	}
	# Allow the user to stop the port forward.
	trap ___recurse SIGINT
	# Port forward pod.
	kubectl port-forward "${POD}" -n "${NAMESPACE}" "${TARGET_PORT}:${PORT}" &
	export PORT_FORWARDING_PID="$!"
	echo "${INFO} press ctrl+c to stop port forwarding"
	wait "$!"
}

# __rerun triggers an entire re-run of the core logic and external operations.
function __rerun() {
	# Check for external dependencies.
	___external_operations
	# Re-run the core logic.
	___core
}

###############
# LEVEL 1 FNs #
###############

# ___core incorporates the core logic.
# _define_levels sets values for various message levels.
function _define_levels() {
	# Initialize colors.
	RED="$(tput setaf 1)"
	YELLOW="$(tput setaf 3)"
	BLUE="$(tput setaf 4)"
	NC="$(tput sgr0)" # No Color.

	# Initialize levels.
	INFO="${BLUE}INFO${NC}"
	WARN="${YELLOW}WARN${NC}"
	ERR="${RED}ERROR${NC}"
}

# _input takes in, and verifies the arguments.
function _input() {
	USAGE="$(
		echo -e "${INFO} usage: $0 <ARG/FLAG> \\n
      -a|--target-port \\n
      [-b|--port] \\n
      -c|--container \\n
      -d|--dockerfile \\n
      [-k|--kind] \\n
      -n|--namespace \\n
      -p|--pod-prefix \\n
      -r|--resource-name \\n
      [-x|--proc] \\n
      [-B|--bypass-entrypoint-check] \\n
    "
	)"

	# Check if the script was invoked without arguments.
	if [ "$#" -eq 0 ]; then
		echo "${ERR} no arguments provided"
		echo "${USAGE}"
		exit 1
	fi

	# Input parameters as long args.
	while [[ $# -gt 0 ]]; do
		key="$1"
		case ${key} in
		-a | --target-port)
			TARGET_PORT="$2"
			shift # past argument
			shift # past value
			;;
		-b | --port)
			PORT="$2"
			shift # past argument
			shift # past value
			;;
		-c | --container)
			CONTAINER="$2"
			shift # past argument
			shift # past value
			;;
		-d | --dockerfile)
			DOCKERFILE="$2"
			shift # past argument
			shift # past value
			;;
		-k | --kind)
			KIND="$2"
			shift # past argument
			shift # past value
			;;
		-n | --namespace)
			NAMESPACE="$2"
			shift # past argument
			shift # past value
			;;
		-p | --pod-prefix)
			POD_PREFIX="$2"
			shift # past argument
			shift # past value
			;;
		-r | --resource-name)
			RESOURCE_NAME="$2"
			shift # past argument
			shift # past value
			;;
		-x | --proc)
			PROC="$2"
			shift # past argument
			shift # past value
			;;
		-B | --bypass-entrypoint-check)
			BYPASS_ENTRYPOINT_CHECK="$2"
			shift # past argument
			shift # past value
			;;
		*)     # unknown option
			shift # past argument
			;;
		esac
	done

	# Exit if any parameter is missing.
	if
		[ -z "${TARGET_PORT}" ] ||
			[ -z "${CONTAINER}" ] ||
			[ -z "${DOCKERFILE}" ] ||
			[ -z "${NAMESPACE}" ] ||
			[ -z "${POD_PREFIX}" ] ||
			false
	then
		echo "${USAGE}"
		exit 1
	fi

	# Set PORT to TARGET_PORT if it is not set.
	if [ -z "${PORT}" ]; then
		PORT="${TARGET_PORT}"
	fi

	# Set PROC to CONTAINER if it is not set.
	if [ -z "${PROC}" ]; then
		PROC="${CONTAINER}"
	fi

	# Set KIND to csv if it is not set.
	if [ -z "${KIND}" ]; then
		KIND="csv"
	fi

	POD="$(__deduce_pod)"
	# Check if the POD value is an existing pod in the cluster.
	kubectl get pod "${POD}" -n "${NAMESPACE}" -o json >/dev/null
	if [ "$?" -eq 1 ]; then
		echo "${ERR} pod ${POD} does not exist in the cluster"
		exit 1
	fi
}

# _prerequisites_met enforces additional checks.
function _prerequisites_met() {
	# Individual checks for granular errors.
	# Check if namespace exists.
	if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
		echo "${ERR} ${NAMESPACE} does not exist"
		exit 1
	fi

	# Check if pod exists inside the given namespace.
	if ! kubectl get pod -n "${NAMESPACE}" "${POD}" >/dev/null 2>&1; then
		echo "${ERR} ${NAMESPACE}/${POD} does not exist"
		exit 1
	fi

	# Check if container exists in the given pod.
	if ! kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].name}' >/dev/null 2>&1; then
		echo "${ERR} ${POD}:${CONTAINER} does not exist"
		exit 1
	fi

	# Check if port is exposed in the given pod.
	if ! kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].ports[?(@.containerPort == '"${TARGET_PORT}"')].containerPort}' >/dev/null 2>&1; then
		echo "${ERR} ${POD}:${CONTAINER} does not have ${TARGET_PORT} exposed"
		exit 1
	fi

	# Check if the container's binary is same as the given proc.
	if ! kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.containers[?(@.name == "'"${CONTAINER}"'")].command}' | grep -wq "${PROC}"; then
		echo "${WARN} ${POD}:${CONTAINER} does not have ${PROC} binary as entrypoint"
		# shellcheck disable=SC2091
		$(${BYPASS_ENTRYPOINT_CHECK}) || exit 1
	fi

	# Check if the provided dockerfile exists.
	if ! [ -f "${DOCKERFILE}" ]; then
		echo "${ERR} ${DOCKERFILE} does not exist"
		exit 1
	fi
}

# _verify_dependencies checks if all dependencies are installed and globally available.
function _verify_dependencies() {
	# Check if kubectl exists in PATH.
	if ! command -v kubectl >/dev/null 2>&1; then
		echo "${ERR} kubectl not found in PATH."
		exit 1
	fi

	# Install kubectl if not installed.
	if ! kubectl version --client >/dev/null 2>&1; then
		# Ask if the user wants to install kubectl.
		echo "${INFO} kubectl not found in PATH. Install kubectl? (Y/n)"
		read -r answer
		if [ "${answer}" == "n" ]; then
			exit 1
		else
			# Install kubectl.
			echo "${INFO} installing kubectl"
			curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" &&
				curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256" &&
				echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
			NO_SUDO_BIN="${HOME}/.local/bin"
			chmod +x kubectl
			mkdir -p "${NO_SUDO_BIN}"
			mv ./kubectl ~/.local/bin/kubectl
			echo "${INFO} kubectl installed"
			# check if ~/.local/bin is in $PATH.
			if ! echo "${PATH}" | grep -q "^${HOME}/.local/bin$"; then
				echo "${INFO} run the command below to add it to your PATH"
				# shellcheck disable=SC2016
				echo 'export PATH="$HOME/.local/bin:$PATH"'
			fi
		fi
	fi

	# Check if GOBIN exists.
	if [ -z "${GOBIN}" ]; then
		echo "${ERR} GOBIN not set."
		exit 1
	fi

	# Check if $GOBIN is in $PATH (i.e., is dlv globally available?).
	if ! echo "${PATH}" | grep -q "${GOBIN}"; then
		echo "${WARN} GOBIN not in PATH, falling back to GOPATH/bin"
		# Check if $GOPATH is in $PATH.
		if ! echo "${PATH}" | grep -q "${GOPATH}"; then
			echo "${ERR} GOPATH is not in PATH."
			exit 1
		fi
		export GOBIN="${GOPATH}/bin"
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

	echo "${INFO} max supported watches: $(cat /proc/sys/fs/inotify/max_user_watches)"
}

# _watch monitors the DOCKERFILE's parent directory for any changes.
function _watch() {
	#  if [ -z "${PORT_FORWARDING_PID}" ]; then
	#    true
	#  else
	#    while [ "$(ps "${PORT_FORWARDING_PID}" | awk 'NR==2{print $1}')" == "" ]; do
	#      __relay
	#    done
	#  fi
	# Watch the directory for changes.
	while true; do
		# Get DOCKERFILE's parent directory.
		DOCKERFILE_DIR="$(dirname "${DOCKERFILE}")"
		# Need to use this in the subshells below.
		export DOCKERFILE_DIR
		echo "${INFO} watching ${DOCKERFILE_DIR}, will build when changes are detected"
		OLD_MD5SUM="$(ls -la "${DOCKERFILE_DIR}" | md5sum | awk 'NR==1{print $1}')"
		while true; do
			echo "${INFO} checking for changes"
			if [ "$(ls -la "${DOCKERFILE_DIR}" | md5sum | awk 'NR==1{print $1}')" == "${OLD_MD5SUM}" ]; then
				echo "${INFO} no changes detected"
				sleep 5s
			else
				echo "${INFO} changes detected"
				# Check if PORT_FORWARDING_PID is defined.
				if [ -z "${PORT_FORWARDING_PID}" ]; then
					echo "${INFO} no port forwarding pid present"
				else
					# Check if the user wants to keep debugging, or build.
					echo -e "${INFO} press enter to continue"
					echo -e "${INFO} press c to cleanup and exit"
					# Read user input.
					read -rsn1 answer
					# Check if user pressed enter.
					if [ "${answer}" == "" ]; then
						true
					else
						# Revert SIGTERM trap.
						trap SIGTERM
						# Cleanup and exit.
						___cleanup
						echo -e "${INFO} exiting"
						exit 0
					fi
					echo "${INFO} port forwarding pid present"
					if [ "$(ps ${PORT_FORWARDING_PID} | awk 'NR==2{print $1}')" != "" ]; then
						echo "${INFO} port forwarding process detected, killing"
						kill -9 "${PORT_FORWARDING_PID}"
						# Kill the port forwarding process.
						echo "${INFO} port forwarding process killed"
					else
						echo "${INFO} no port forwarding process detected"
					fi
				fi
				__rerun
			fi
		done
	done
}

###############
# LEVEL 0 FNs #
###############

# alfred is the init method.
function alfred() {
	_define_levels
	_input "$@"
	_verify_dependencies
	_prerequisites_met
	_watch "$@"
}

# Hide ^C from the output.
stty -echoctl

# Run the script.
alfred "$@"

# Reset all modes to reasonable values for the current terminal.
stty sane
