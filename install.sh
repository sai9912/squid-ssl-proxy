#!/bin/bash

apt update -y
apt install docker.io -y
sudo rm /usr/local/bin/docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose


IP=$(ip -4 addr show dev enp1s0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}') && sed -i -E "s|(http_port )[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:8000 .* name=ip1)|\1$IP\2|; s|(tcp_outgoing_address )[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+( to_ip1)|\1$IP\2|" ./squid.conf

