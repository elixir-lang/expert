#!/usr/bin/env bash

project_name=$1
node_name=$(epmd -names | grep manager-"$project_name" | awk '{print $2}')

iex --sname "shell" \
    --remsh "${node_name}" \
    --cookie expert
