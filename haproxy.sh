#[admin@ceph-01 ~]$ 

for host in ceph-0{1..3}
do
ssh ${host} sudo subscription-manager register
done

for host in ceph-0{1..3}
do
ssh ${host} sudo firewall-cmd --zone=public --add-port 80/tcp --permanent
done

for host in ceph-0{1..3}
do
ssh ${host} sudo firewall-cmd --zone=public --add-port 8080/tcp --permanent
done

for host in ceph-0{1..3}
do
ssh ${host} sudo firewall-cmd --reload
done

for host in ceph-0{2..3}
do
ssh ${host} sudo dnf install -y keepalived
done

for host in ceph-0{1..3}
do
ssh ${host} sudo dnf install -y haproxy
done

test -n ${port_vip} || exit 101
test -n ${port_haproxy} || exit 102
test -d ~/haproxy/ || mkdir --parents ~/haproxy/
tee ~/haproxy/haproxy-http.xml 0<<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
<short>HAProxy-HTTP</short>
<description>HAProxy load-balancer</description>
<port protocol="tcp" port="${port_vip}"/>
<port protocol="tcp" port="${port_haproxy}"/>
</service>
EOF

for host in ceph-0{1..3}
do
sudo scp ~/haproxy/haproxy-http.xml ${host}:/etc/firewalld/services/
done

for host in ceph-0{1..3}
do
ssh ${host} sudo systemctl restart firewalld
done

for host in ceph-0{1..3}
do
ssh ${host} sudo restorecon /etc/firewalld/services/haproxy-http.xml
done

for host in ceph-0{1..3}
do
ssh ${host} sudo chmod 640 /etc/firewalld/services/haproxy-http.xml
done

test -n ${ip_haproxy_master} || exit 103
test -n ${ip_haproxy_backup} || exit 104
test -n ${ip_vip} || exit 105
test -n ${interface} || exit 106
test -d ~/keepalived/master/ || mkdir --parents ~/keepalived/master/
tee ~/keepalived/master/keepalived.conf 0<<EOF
vrrp_script chk_haproxy {
    script "killall -0 haproxy" # check the haproxy process
    interval 2 # every 2 seconds
    weight 2 # add 2 points if OK
}
vrrp_instance RGW {
    state MASTER
    @main interface ${interface}
    @main unicast_src_ip ${ip_haproxy_master} ${port_haproxy}
    virtual_router_id 50
    priority 100
    advert_int 1
    unicast_peer {
        ${ip_haproxy_backup}
    }
    authentication {
        auth_type PASS
        auth_pass 1111
    }
    virtual_ipaddress {
        ${ip_vip}
    }
    track_script {
        chk_haproxy
    }
}
virtual_server ${ip_vip} ${port_vip} ${interface} {
    delay_loop 6
    lb_algo wlc
    lb_kind dr
    persistence_timeout 600
    protocol TCP
    real_server ${ip_haproxy_master} ${port_haproxy} {
        weight 100
        TCP_CHECK { # perhaps change these to a HTTP/SSL GET?
            connect_timeout 3
        }
    }
    real_server ${ip_haproxy_backup} ${port_haproxy} {
        weight 100
        TCP_CHECK { # perhaps change these to a HTTP/SSL GET?
            connect_timeout 3
        }
    }
}
EOF

test -d ~/keepalived/backup/ || mkdir --parents ~/keepalived/backup/
tee ~/keepalived/backup/keepalived.conf 0<<EOF
vrrp_script chk_haproxy {
    script "killall -0 haproxy" # check the haproxy process
    interval 2 # every 2 seconds
    weight 2 # add 2 points if OK
}
vrrp_instance RGW {
    state BACKUP # might not be necessary?
    priority 99
    advert_int 1
    interface eno1
    virtual_router_id 50
    unicast_src_ip ${ip_haproxy_backup} ${port_haproxy}
    unicast_peer {
        ${ip_haproxy_master}
    }
    authentication {
        auth_type PASS
        auth_pass 1111
    }
    virtual_ipaddress {
        ${ip_vip}
    }
    track_script {
        chk_haproxy
    }
}
virtual_server ${ip_vip} ${port_vip} ${interface}  {
    delay_loop 6
    lb_algo wlc
    lb_kind dr
    persistence_timeout 600
    protocol TCP
    real_server ${ip_haproxy_master} ${port_haproxy} {
        weight 100
        TCP_CHECK { # perhaps change these to a HTTP/SSL GET?
            connect_timeout 3
        }
    }
    real_server ${ip_haproxy_backup} ${port_haproxy} {
        weight 100
        TCP_CHECK { # perhaps change these to a HTTP/SSL GET?
            connect_timeout 3
        }
    }
}
EOF

for host in ceph-02
do
sudo scp ~/keepalived/master/keepalived.conf ${host}:/etc/keepalived/
done

for host in ceph-03
do
sudo scp ~/keepalived/backup/keepalived.conf ${host}:/etc/keepalived/
done

for host in ceph-0{2..3}
do
ssh ${host} sudo systemctl enable --now keepalived
done

for host in ceph-0{2..3}
do
ssh ${host} sudo systemctl restart keepalived
done

test -n ${ip_rgw_master} || exit 100
test -n ${ip_rgw_backup} || exit 100
test -n ${port_rgw} || exit 100
tee ~/haproxy/haproxy.cfg-ceph-01 0<<EOF
defaults
  option log-health-checks
  timeout connect 5s
  timeout client 50s
  timeout server 450s
frontend http_web
  bind ${ip_haproxy_master}:${port_haproxy} # CHECK!!!
  mode http
  default_backend rgw
backend rgw
  balance roundrobin
  mode http
  server  rgw1 ${ip_rgw_master}:${port_rgw} check
  server  rgw2 ${ip_rgw_backup}:${port_rgw} check
EOF

tee ~/haproxy/haproxy.cfg-ceph-02 0<<EOF
defaults
  option log-health-checks
  timeout connect 5s
  timeout client 50s
  timeout server 450s
frontend http_web
  bind ${ip_haproxy_master}:${port_haproxy}
  mode http
  default_backend rgw
backend rgw
  balance roundrobin
  mode http
  server  rgw1 ${ip_rgw_master}:${port_rgw} check
  server  rgw2 ${ip_rgw_backup}:${port_rgw} check
EOF

tee ~/haproxy/haproxy.cfg-ceph-03 0<<EOF
defaults
  option log-health-checks
  timeout connect 5s
  timeout client 50s
  timeout server 450s
frontend http_web
  bind ${ip_haproxy_backup}:${port_haproxy}
  mode http
  default_backend rgw
backend rgw
  balance roundrobin
  mode http
  server  rgw1 ${ip_rgw_master}:${port_rgw} check
  server  rgw2 ${ip_rgw_backup}:${port_rgw} check
EOF

for host in ceph-0{1..3}
do
sudo scp ~/haproxy/haproxy.cfg-${host} ${host}:/etc/haproxy/haproxy.cfg
done

for host in ceph-0{1..3}
do
ssh ${host} sudo systemctl enable --now haproxy
done

for host in ceph-0{1..3}
do
ssh ${host} sudo systemctl restart haproxy
done

for host in ceph-0{1..3} ; do echo ; echo $host ; ssh ${host} sudo ss -l -n -t -p | grep -E ":${port_vip}|:${port_haproxy}|:${port_rgw}" | sort -k 6 ; done

for host in ceph-0{1..3} ; do echo ; echo $host ; ssh ${host} curl --connect-timeout 3 -s -I ${ip_vip}:${port_vip} ; done



