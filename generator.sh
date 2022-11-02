#!/bin/sh

# centos 7.5

GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

eecho() {
    echo -e "${GREEN}$1${NC}"
}

eecho "Getting IPv4 ..."
IP4=$(curl -4 -s icanhazip.com -m 10)

eecho "Getting IPv6 ..."
IP6=$(curl -6 -s icanhazip.com -m 10)
if [[ $IP6 != *:* ]]; then
  IP6=
fi

eecho "IPv4 = ${IP4}. IPv6 = ${IP6}"

if [ ! -n "$IP4" ]; then
  eecho "IPv4 Nout Found. Exit"
  exit
fi

while [[ $IP6 != *:* ]] || [ ! -n "$IP6" ]; do
    eecho "IPv6 Nout Found, Please check environment. Exit"
    exit
#   eecho "Invalid IPv6, Please input it manually:"
#   read IP6
done

while [ ! $PROXYCOUNT ] || [[ $PROXYCOUNT -lt 1 ]] || [[ $PROXYCOUNT -gt 10000 ]]; do
    eecho "How many proxy do you want to create? 1-10000"
    read PROXYCOUNT
done

while [ ! -n "$STATIC" ]; do
    eecho "Do you want to use static mode: (yes/no, no as default)"
    read STATIC
    if [[ $STATIC == "y" ]] || [[ $STATIC == "yes" ]]; then
        STATIC="yes"
    else
        STATIC="no"
    fi
done

while [[ $IP6PREFIXLEN -ne 48 ]] && [[ $IP6PREFIXLEN -ne 64 ]] && [[ $IP6PREFIXLEN -ne 112 ]]; do
    eecho "Please input prefixlen for IPv6: (48/64/112, 112 as default)"
    read IP6PREFIXLEN
    if [ ! $IP6PREFIXLEN ]; then
        IP6PREFIXLEN=112
    fi
done

if [[ $IP6PREFIXLEN -eq 112 ]]; then
    INCTAIL="yes"
else
    while [ ! -n "$INCTAIL" ]; do
        eecho "Do you want to use [increasing tail] way to generate addresses: (yes/no, no as default)"
        read INCTAIL
        if [[ $INCTAIL == "y" ]] || [[ $INCTAIL == "yes" ]]; then
            INCTAIL="yes"
        else
            INCTAIL="no"
        fi
    done
fi

if [[ $INCTAIL == "yes" ]]; then
    while [ ! -n "$INCTAILSTEPS" ]; do
        eecho "How many steps do you want for [increasing tail] way: (1 as default)"
        read INCTAILSTEPS
        if [[ $INCTAILSTEPS -lt 1 ]]; then
            INCTAILSTEPS=1
        fi
    done
fi

if [[ $INCTAIL == "yes" ]]; then
    IP6PREFIX=$(echo $IP6 | rev | cut -f2- -d':' | rev)
else
    if [ $IP6PREFIXLEN -eq 48 ]; then
        IP6PREFIX=$(echo $IP6 | cut -f1-3 -d':')
    fi
    if [ $IP6PREFIXLEN -eq 64 ]; then
        IP6PREFIX=$(echo $IP6 | cut -f1-4 -d':')
    fi
fi
eecho "IPv6 PrefixLen: $IP6PREFIXLEN --> Prefix: $IP6PREFIX"

while [ ! -n "$ETHNAME" ]; do
  eecho "Please input network interface name: (eth0 as default)"
  read ETHNAME
  if [[ $ETHNAME == "" ]]; then
    ETHNAME="eth0"
  fi
done

while [ ! -n "$PROXYUSER" ]; do
    eecho "Please input username for proxy: (ipman as default)"
    read PROXYUSER
    if [[ $PROXYUSER == "" ]]; then
        PROXYUSER="ipman"
    fi
done

while [ ! -n "$PROXYPASS" ]; do
    eecho "Please input password for proxy: (crystal as default)"
    read PROXYPASS
    if [[ $PROXYPASS == "" ]]; then
        PROXYPASS="crystal"
    fi
done

#################### functions ####################
gen_data() {
    array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    ip64() {
		echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
	}

    seq 1 $PROXYCOUNT | while read idx; do
        port=$(($idx+10000))
        if [[ $INCTAIL == "yes" ]] ; then
            suffix=$((($idx)*$INCTAILSTEPS))
            suffix=$(printf '%x\n' $suffix)
            echo "$PROXYUSER/$PROXYPASS/$IP4/$port/$IP6PREFIX:$suffix"
        else
            if [[ $IP6PREFIXLEN -eq 64 ]]; then
                echo "$PROXYUSER/$PROXYPASS/$IP4/$port/$IP6PREFIX:$(ip64):$(ip64):$(ip64):$(ip64)"
            fi
            if [[ $IP6PREFIXLEN -eq 48 ]]; then
                echo "$PROXYUSER/$PROXYPASS/$IP4/$port/$IP6PREFIX:$(ip64):$(ip64):$(ip64):$(ip64):$(ip64)"
            fi
        fi
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -v ETHNAME="$ETHNAME" -v IP6PREFIXLEN="$IP6PREFIXLEN" -F "/" '{print "ifconfig " ETHNAME " inet6 add " $5 "/" IP6PREFIXLEN}' ${WORKDATA})
EOF
}

gen_static() {
    NETWORK_FILE="/etc/sysconfig/network-scripts/ifcfg-$ETHNAME"
    cat <<EOF
    sed -i '/^IPV6ADDR_SECONDARIES/d' $NETWORK_FILE && echo 'IPV6ADDR_SECONDARIES="$(awk -v IP6PREFIXLEN="$IP6PREFIXLEN" -F "/" '{print $5 "/" IP6PREFIXLEN}' ${WORKDATA} | sed -z 's/\n/ /g')"' >> $NETWORK_FILE
EOF
}

gen_proxy_file() {
    cat <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}


install_3proxy() {
    eecho "Installing 3proxy ..."
    git clone https://github.com/cturan/3proxy
    cd 3proxy
    ln -s Makefile.Linux Makefile
    make
    make install
    cd ..
}


gen_3proxy() {
    cat <<EOF
nscache 65536
nserver 8.8.8.8
nserver 8.8.4.4
config /conf/3proxy.cfg
monitor /conf/3proxy.cfg
counter /count/3proxy.3cf
include /conf/counters
include /conf/bandlimiters
users $(awk -F "/" '{print $1 ":CL:" $2}' ${WORKDATA} | uniq | sed -z 's/\n/ /g')
flush
$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

####################
eecho "Installing apps ... (yum)"
yum -y install gcc net-tools bsdtar zip git make

###################
install_3proxy 

# ###################
WORKDIR="/usr/local/3proxy/installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR
eecho "Working folder = $WORKDIR"

gen_data >$WORKDATA
gen_3proxy >/usr/local/3proxy/conf/3proxy.cfg
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
gen_static >$WORKDIR/boot_static.sh

BOOTRCFILE="$WORKDIR/boot_rc.sh"

REGISTER_LOGIC="bash ${WORKDIR}/boot_ifconfig.sh"
if [[ $STATIC == "yes" ]]; then
    REGISTER_LOGIC="bash ${WORKDIR}/boot_static.sh && systemctl restart network"
fi

cat >$BOOTRCFILE <<EOF
bash ${WORKDIR}/boot_iptables.sh
${REGISTER_LOGIC}
systemctl restart 3proxy
systemctl stop firewalld
systemctl disable firewalld
systemctl disable firewalld.service
EOF
chmod +x ${WORKDIR}/boot_*.sh


# change ulimit for too many open files
grep -qxF '* soft nofile 1024000' /etc/security/limits.conf || cat >>/etc/security/limits.conf <<EOF 
* soft nofile 1024000
* hard nofile 1024000
EOF

# qxF match whole line
grep -qxF "bash $BOOTRCFILE" /etc/rc.local || cat >>/etc/rc.local <<EOF 
bash $BOOTRCFILE
EOF
chmod +x /etc/rc.local
bash /etc/rc.local

PROXYFILE=proxy.txt
gen_proxy_file >$PROXYFILE
eecho "Done with $PROXYFILE"

zip --password $PROXYPASS proxy.zip $PROXYFILE
URL=$(curl -s --upload-file proxy.zip https://transfer.sh/ipv6proxy.zip)

eecho "Proxy is ready! Format IP:PORT:LOGIN:PASS"
eecho "Download zip archive from: ${URL}"
eecho "Password: ${PROXYPASS}"
