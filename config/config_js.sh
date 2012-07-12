ROOT=/a
LIBRARY="${SI_CONFIG_DIR}/bin/library.ksh"
F_DIR="${SI_CONFIG_DIR}/finish_scripts"
SERVER_IP="10.10.8.106"
LOG_SHARE="/var/log/js"
CLIENT=$SI_HOSTNAME
CONF_DIR="${SI_CONFIG_DIR}/clients/$CLIENT"
CLIENT_LOG_DIR="${ROOT}/var/sadm/system/logs"
CLIENT_LOG_FILE="${CLIENT_LOG_DIR}/jumpstart.log"
SERVER_LOG_MNT="/a/log"
SERVER_LOG_DIR="${SERVER_LOG_MNT}/clients/$CLIENT"
SERVER_LOG_FILE="$SERVER_LOG_DIR/${CLIENT}.jumpstart_log"

