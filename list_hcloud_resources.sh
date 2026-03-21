#!/usr/bin/env bash

echo "Servers:"
hcloud server list

echo "Load-Balancers"
hcloud load-balancer list

echo "Floating IPs"
hcloud floating-ip list

echo "Snapshots"
hcloud image list --type snapshot
