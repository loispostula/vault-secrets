#!/usr/bin/env bash

set -euo pipefail

token_data="$(openbao token lookup -format=json)"
openbao_token_never_expire="$(jq '.data.expire_time == null' <<< "$token_data")"
openbao_token_ttl="$(jq '.data.ttl' <<< "$token_data")"
if [[ $openbao_token_never_expire == false && $openbao_token_ttl -le 0 ]]; then
    echo 'Openbao token expired or invalid. Please log into openbao first.'
    exit 1
fi
