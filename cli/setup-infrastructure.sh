#!/bin/bash
# Master setup - runs both infrastructure scripts

./cli/setup-ingress-controller.sh
./cli/setup-complete-cicd.sh