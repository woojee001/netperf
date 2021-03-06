#!/bin/bash

# This script copies toolkit configuration files and data stores to a tar archive.

tar -cvPf perfsonar_recover.tar /etc/bwctld/bwctld.limits
tar -rvPf perfsonar_recover.tar /etc/bwctld/bwctld.conf
tar -rvPf perfsonar_recover.tar /etc/bwctld/bwctld.keys
tar -rvPf perfsonar_recover.tar /etc/hosts
tar -rvPf perfsonar_recover.tar /etc/maddash/maddash-server/maddash.yaml
tar -rvPf perfsonar_recover.tar /etc/ntp/keys
tar -rvPf perfsonar_recover.tar /etc/ntp/step-tickers
tar -rvPf perfsonar_recover.tar /etc/owampd/owampd.conf
tar -rvPf perfsonar_recover.tar /etc/owampd/owampd.limits
tar -rvPf perfsonar_recover.tar /etc/owampd/owampd.pfs
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/lookup_service/etc/daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/lookup_service/etc/daemon_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/ls_registration_daemon/etc/ls_registration_daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/ls_registration_daemon/etc/ls_registration_daemon-logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/perfsonarbuoy_ma/etc/daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/perfsonarbuoy_ma/etc/daemon_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/perfsonarbuoy_ma/etc/owmesh.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/PingER/etc/daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/PingER/etc/daemon_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/PingER/etc/pinger-landmarks.xml
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/snmp_ma/etc/daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/snmp_ma/etc/daemon_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/administrative_info
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/backingstore.conf.d/
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/backingstore.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/discover_external_address.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/discover_external_address-logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/enabled_services
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/external_addresses
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/config_daemon-logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/default_service_configs/
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/service_watcher.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/service_watcher-logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/ntp_known_servers
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/toolkit/etc/config_daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/ondemand_mp-daemon_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/traceroute-master.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/daemon_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/traceroute-master_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/ondemand_mp-daemon.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/traceroute-scheduler_logger.conf
tar -rvPf perfsonar_recover.tar /opt/perfsonar_ps/traceroute_ma/etc/owmesh.conf
tar -rvPf perfsonar_recover.tar /usr/ndt/tcpbw100.html
tar -rvPf perfsonar_recover.tar /var/lib/cacti/rra/
tar -rvPf perfsonar_recover.tar /var/lib/mysql/
tar -rvPf perfsonar_recover.tar /var/lib/npad/diag_form.html
tar -rvPf perfsonar_recover.tar /var/lib/owamp/
tar -rvPf perfsonar_recover.tar /var/lib/perfsonar/
tar -rvPf perfsonar_recover.tar /var/log/ndt/
tar -rvPf perfsonar_recover.tar /var/log/ntpd
tar -rvPf perfsonar_recover.tar /var/log/perfsonar/*log*
