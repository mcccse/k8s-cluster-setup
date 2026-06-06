#!/usr/bin/env bash

YES=0
if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
  YES=1
  shift
fi

if [[ "$YES" -eq 1 ]]; then
  yes | ./install_hccm.sh &&
    yes | ./install_cilium.sh &&
    yes | ./install_gateway.sh
else
  ./install_hccm.sh &&
    ./install_cilium.sh &&
    ./install_gateway.sh
fi
