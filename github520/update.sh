#!/bin/bash
sed -i "/# GitHub520 Host Start/Q" /etc/hosts
curl -fsSL https://raw.hellogithub.com/hosts >> /etc/hosts
