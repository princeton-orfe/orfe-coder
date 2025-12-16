[Interface]
PrivateKey = ${server_private_key}
Address = ${server_address}/24
ListenPort = ${listen_port}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

%{ for peer in peers ~}
# ${peer.name}
[Peer]
PublicKey = ${peer.public_key}
AllowedIPs = ${peer_ips[peer.name]}/32

%{ endfor ~}
