#!/usr/bin/env bash
# Shared by monorepo image publishers; syntax does not establish ownership.
# Caller must still select an explicitly owned destination, never a default.
validate_docker_image() {
  local IMAGE="${1:-}" component label registry port
  component='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
  label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
  registry="${label}(\.${label})*(:[0-9]{1,5})?"
  if [[ ${#IMAGE} -gt 255 || ! "$IMAGE" =~ ^${registry}/${component}(/${component})*$ ]]; then
    echo "error: set DOCKER_IMAGE to an explicit untagged namespace/repository or registry[:port]/repository you own" >&2
    return 1
  fi
  if [[ "${IMAGE%%/*}" == *:* ]]; then
    port="${IMAGE%%/*}"
    port="${port##*:}"
    if (( 10#$port < 1 || 10#$port > 65535 )); then
      echo "error: DOCKER_IMAGE registry port must be between 1 and 65535" >&2
      return 1
    fi
  fi
}
