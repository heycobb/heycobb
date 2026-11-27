#!/bin/zsh
# Runs ArkenalKit's server round-trip tests against the local test servers
# (start them first: docker compose -f Tools/test-servers/compose.yml up -d).
# Usage: run-tests.sh [webdav|smb]   (both if omitted)

here=${0:A:h}
pass() { grep -A1 "$1" $here/compose.yml | grep -oE 't-[0-9a-f]+' | head -1 }
cd $here/../../Packages/ArkenalKit
run() {
  echo "== $1"
  ARKENAL_IT_NEXTCLOUD=$ARKENAL_IT_NEXTCLOUD ARKENAL_IT_URL=$2 ARKENAL_IT_USER=arkenal ARKENAL_IT_PASS=$3 ARKENAL_IT_SHARE=$4 \
    script -q /dev/null swift test --filter ServerRoundTripTests 2>&1 | grep -E "✘|✔ Test|passed after|failed after|error:"
}
[[ -z $1 || $1 == webdav ]] && ARKENAL_IT_NEXTCLOUD=localhost:8443 run "Nextcloud (WebDAV)" "https://localhost:8443/remote.php/webdav/" "$(pass NEXTCLOUD_ADMIN_PASSWORD)" Documents
[[ -z $1 || $1 == smb ]] && run "Samba (SMB)" "smb://localhost:1445" "$(pass 'PASS:')" Data
true
