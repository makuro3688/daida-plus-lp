#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
CONFIG_DIR="${HOME}/.config/rclone"
CONFIG_FILE="${CONFIG_DIR}/rclone.conf"
CLIENT_ID_FILE="${CONFIG_DIR}/.daida-client-id.tmp"
POWERSHELL_EXE="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

read_clipboard() {
  "${POWERSHELL_EXE}" -NoProfile -NonInteractive -Command 'Get-Clipboard -Raw' 2>/dev/null \
    | tr -d '\r\n'
}

clear_clipboard() {
  "${POWERSHELL_EXE}" -NoProfile -NonInteractive -Command 'Set-Clipboard -Value ""' \
    >/dev/null 2>&1 || true
}

mkdir -p "${CONFIG_DIR}"
chmod 700 "${CONFIG_DIR}"
umask 077

case "${ACTION}" in
  capture-client-id)
    client_id="$(read_clipboard)"
    if [[ ! "${client_id}" =~ ^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$ ]]; then
      clear_clipboard
      echo "Clipboard does not contain a valid Google OAuth client ID." >&2
      exit 1
    fi
    printf '%s' "${client_id}" > "${CLIENT_ID_FILE}"
    chmod 600 "${CLIENT_ID_FILE}"
    clear_clipboard
    unset client_id
    echo "OAuth client ID captured securely."
    ;;

  configure-client-secret)
    if [[ ! -s "${CLIENT_ID_FILE}" ]]; then
      echo "OAuth client ID has not been captured yet." >&2
      exit 1
    fi
    client_secret="$(read_clipboard)"
    clear_clipboard
    if [[ -z "${client_secret}" || ${#client_secret} -lt 10 ]]; then
      unset client_secret
      echo "Clipboard does not contain a valid OAuth client secret." >&2
      exit 1
    fi
    client_id="$(<"${CLIENT_ID_FILE}")"
    if ! command -v rclone >/dev/null 2>&1; then
      unset client_id client_secret
      echo "rclone is not installed." >&2
      exit 1
    fi
    rclone config create gdrive drive \
      client_id "${client_id}" \
      client_secret "${client_secret}" \
      scope drive.file \
      >/dev/null
    chmod 600 "${CONFIG_FILE}"
    rm -f -- "${CLIENT_ID_FILE}"
    unset client_id client_secret
    echo "Google Drive remote created with drive.file scope."
    ;;

  configure-file)
    credential_file="${2:-}"
    if [[ -z "${credential_file}" || ! -f "${credential_file}" ]]; then
      echo "Credential transfer file was not found." >&2
      exit 1
    fi
    IFS= read -r client_id < "${credential_file}"
    client_secret="$(sed -n '2p' "${credential_file}")"
    if [[ ! "${client_id}" =~ ^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$ ]]; then
      unset client_id client_secret
      echo "Credential transfer file contains an invalid client ID." >&2
      exit 1
    fi
    if [[ -z "${client_secret}" || ${#client_secret} -lt 10 ]]; then
      unset client_id client_secret
      echo "Credential transfer file contains an invalid client secret." >&2
      exit 1
    fi
    if ! command -v rclone >/dev/null 2>&1; then
      unset client_id client_secret
      echo "rclone is not installed." >&2
      exit 1
    fi
    rclone config create gdrive drive \
      client_id "${client_id}" \
      client_secret "${client_secret}" \
      scope drive.file \
      >/dev/null
    chmod 600 "${CONFIG_FILE}"
    unset client_id client_secret
    echo "Google Drive remote created with drive.file scope."
    ;;

  *)
    echo "Usage: $0 capture-client-id|configure-client-secret|configure-file <path>" >&2
    exit 2
    ;;
esac
