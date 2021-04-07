#!/bin/bash

interfaceWifi=wlan0
ipAddress=192.168.4.1/24
dns="84.200.69.80 84.200.70.40"
networks=()
country=us
supplicantFile=/etc/wpa_supplicant/wpa_supplicant-${interfaceWifi}.conf

OPTIONS=hw:e:i:n:s:c:
LONGOPTS=help,wireless:,ethernet:,ip-address:,network:,ssid:,country:

usage() {
	echo
	echo "auto-hotspot"
	echo
	echo "Install WPA supplicant configs and a service to enable a WiFi hotspot"
	echo "if no other known networks are visible. Known networks will be"
	echo "connected to if they become available and no devices are connected to"
	echo "the hotspot"
	echo
	echo "usage:"
  echo "  install.sh [-h/--help] [-w/--wireless <interface>] [-i/--ip-address <interface>]"
	echo "    [-n/--network <network>] [-d/--dns <dns>] [-c/--country <country>]"
	echo "    [-s/--ssid <ssid> -p/--password <password>]"
	echo
	echo "  -w,--wireless <interface>  Use <interface> as the hotspot wireless"
	echo "                             interface. Default wlan0"
	echo "  -e,--ethernet <interface>  If given, a hotspot will not be set up"
	echo "                             if the ethernet interface <interface>"
	echo "                             is connected"
	echo "  -i,--ip-address <address>  The IPv4 IP address to use for this"
	echo "                             computer when the hotspot is active."
	echo "                             Default 192.168.4.1/24"
	echo "  -s,--ssid <ssid>           SSID to use for the hotspot. If given"
	echo "                             the WPA supplicant configuration file"
	echo "                             for the wireless interface will be"
	echo "                             recreated"
	echo "  -p,--password <password>   Password for the hotspot if SSID is"
	echo "                             given"
	echo "  -c,--country <code>        Two letter country code for your country"
	echo "                             Default us. For the UK this should be gb"
	echo "  -n,--network <network>     Network to configure to connect to if"
	echo "                             a hotspot SSID is given."
	echo "                             <network> should be the form"
	echo "                             SSID,password"
	echo "                             and cannot contain commas in the SSID"
	echo "                             or the pasword"
	echo "  -d,--dns <dns>             The DNS servers, separated by spaces"
	echo "                             to give to clients that connect to the"
	echo "                             hotspot. Defaults to the DNSWatch servers"
	echo "                             84.200.69.80 84.200.70.40"
	echo "  -h,--help                  Show this help"
}

# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via	 -- "$@"	 to separate them correctly
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
		# e.g. return value is 1
		#	then getopt has complained about wrong arguments to stdout
		exit 2
fi
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

DEBUG=false
VERBOSE=false

# now enjoy the options in order and nicely split until we see --
while true; do
		case "$1" in
				-h|--help)
					usage
					exit 0
						;;
				-w|--wireless)
						interfaceWifi="$2"
						shift 2
						;;
				-e|--ethernet)
						interfaceWired="$2"
						shift 2
						;;
				-i|--ip-address)
						ipAddress="$2"
						shift 2
						;;
				-d|--dns)
						dns="$2"
						shift 2
						;;
				-s|--ssid)
						ssid="$2"
						shift 2
						;;
				-p|--password)
						password="$2"
						shift 2
						;;
				-c|--country)
						country="$2"
						shift 2
						;;
				-n|--network)
						networks+="$2"
						shift 2
						;;
				--)
						shift
						break
						;;
				*)
						echo "Unknown option $1"
						usage
						exit 3
						;;
		esac
done

if [ "$ssid" != "" ] && [ "$password" == "" ]; then
	echo "You need to provide a password for the hotspot"
	usage
	exit 1
fi

### Check if run as root ############################
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root" 
	echo "Try \"sudo $0\""	
	exit 1
fi
	
## Change over to systemd-networkd
## https://raspberrypi.stackexchange.com/questions/108592
# deinstall classic networking
apt --autoremove -y purge ifupdown dhcpcd5 isc-dhcp-client isc-dhcp-common rsyslog
apt-mark hold ifupdown dhcpcd5 isc-dhcp-client isc-dhcp-common rsyslog raspberrypi-net-mods openresolv
rm -r /etc/network /etc/dhcp

# setup/enable systemd-resolved and systemd-networkd
apt --autoremove -y purge avahi-daemon
apt-mark hold avahi-daemon libnss-mdns
apt install -y libnss-resolve
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-networkd.service systemd-resolved.service

## Install configuration files for systemd-networkd
if [ "$interfaceWired" != "" ]; then
	cat > /etc/systemd/network/04-${interfaceWired}.network <<-EOF
		[Match]
		Name=$interfaceWired
		[Network]
		DHCP=yes
	EOF
fi

cat > /etc/systemd/network/08-${interfaceWifi}-CLI.network <<-EOF
	[Match]
	Name=$interfaceWifi
	[Network]
	DHCP=yes
	LinkLocalAddressing=yes
	MulticastDNS=yes
EOF
		
cat > /etc/systemd/network/12-${interfaceWifi}-AP.network <<-EOF
	[Match]
	Name=$interfaceWifi
	[Network]
	Address=$ipAddress
	IPForward=yes
	IPMasquerade=yes
	DHCPServer=yes
	LinkLocalAddressing=yes
	MulticastDNS=yes
	[DHCPServer]
	DNS=$dns
EOF

if [ "$ssid" != "" ]; then
	if [ -e $supplicantFile ]; then
		mv $supplicantFile ${supplicantFile}.old
	fi
	cat > $supplicantFile <<-EOF
		country=$country
		ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
		update_config=1
		ap-scan=1

		network={
			priority=0
			ssid="$ssid"
			mode=2
			key_mgmt=WPA-PSK
			psk="$password"
		}
	EOF

	if [ "${#networks[@]}" != "0" ]; then
		for network in "${networks[@]}"; do
			cat >> $supplicantFile <<-EOF

				network={
					ssid="$(echo -n "$network" | cut -d ',' -f 1)"
					psk="$(echo -n "$network" | cut -d ',' -f 2)"
				}
			EOF
		done
	fi
fi

cat $(pwd)/auto-hotspot | sed -e "s/wlan0/$interfaceWifi/" \
		-e "s/eth0/interfaceWired/" > /usr/local/sbin/auto-hotspot
chmod +x /usr/local/sbin/auto-hotspot

## Install systemd-service to configure interface automatically
if [ ! -f /etc/systemd/system/wpa_cli@${interfaceWifi}.service ] ; then
	cat > /etc/systemd/system/wpa_cli@${interfaceWifi}.service <<-EOF
		[Unit]
		Description=Wpa_cli to automatically create an accesspoint if no client connection is available
		After=wpa_supplicant@%i.service
		BindsTo=wpa_supplicant@%i.service
		[Service]
		ExecStart=/sbin/wpa_cli -i %I -a /usr/local/sbin/auto-hotspot
		Restart=on-failure
		RestartSec=1
		[Install]
		WantedBy=multi-user.target
	EOF
else
	echo "wpa_cli@$interfaceWifi.service is already installed"
fi

systemctl daemon-reload
systemctl enable wpa_cli@${interfaceWifi}.service
echo "Reboot now!"
exit 0
