# zcoffee: Azure Local 2-Node Lab Deployment

## Overview
This repo contains automation scripts and documentation to deploy a 2-node Azure Local cluster with Storage Spaces Direct (S2D), Hyper-V, and switchless networking.

## Prerequisites
- Dell PowerEdge R650 (2 nodes)
- VLAN 230, subnet 10.8.230.0/24
- Sangfor VPN access
- VS Code with PowerShell + ARM Tools extensions
- Azure subscription (see private runbook for details)

## Quickstart
1. Clone the repo
   ```bash
   git clone https://github.com/andrijun0406/zcoffee.git
