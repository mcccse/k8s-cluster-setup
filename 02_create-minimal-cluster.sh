#!/usr/bin/env bash

CP_REPLICAS=1 WORKER_REPLICAS=1 ./create_cluster.sh &&
  sleep 5 &&
  ./get_credentials.sh
