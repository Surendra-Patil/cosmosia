pacman -Syu --noconfirm
pacman -S --noconfirm base-devel dnsutils python nginx logrotate

########################################################################################################################
# netdata

bash <(curl -Ss https://my-netdata.io/kickstart.sh)
sleep 5

killall netdata

curl -s https://raw.githubusercontent.com/baabeetaa/cosmosia/main/proxy/netdata.conf > /opt/netdata/netdata-configs/netdata.conf
curl -s https://raw.githubusercontent.com/baabeetaa/cosmosia/main/proxy/netdata.python.d.nginx.conf > /opt/netdata/netdata-configs/python.d/nginx.conf
curl -s https://raw.githubusercontent.com/baabeetaa/cosmosia/main/proxy/netdata.python.d.web_log.conf > /opt/netdata/etc/netdata/python.d/web_log.conf

/opt/netdata/bin/srv/netdata
sleep 5

########################################################################################################################
# dynamic upstream

RPC_SERVICES="osmosis starname regen akash cosmoshub sentinel emoney ixo juno sifchain likecoin kichain cyber cheqd stargaze bandchain chihuahua kava bitcanna konstellation omniflixhub terra vidulum provenance dig gravitybridge"
UPSTREAM_CONFIG_FILE="/etc/nginx/upstream.conf"
TMP_DIR="$HOME/tmp/upstream"
TMP_UPSTREAM_CONFIG_FILE="$TMP_DIR/new_upstream_config.conf"

mkdir -p $TMP_DIR
rm -rf "$TMP_DIR/*"

# functions
generate_new_upstream_config () {
  echo "# This file is generated dynamically, dont edit." > $TMP_UPSTREAM_CONFIG_FILE

  for service_name in $RPC_SERVICES; do
    # use dig to figure out IPs of service
    new_ips=$(dig +short "tasks.$service_name" |sort)

    addr_str=""
    addr_str_grpc=""
    if [[ -z $new_ips ]]; then
        # write a dummy address and port so that nginx wont complain
        addr_str="    server 127.0.0.1:1;"
        addr_str_grpc="    server 127.0.0.1:1;"
    else
      is_healthy=false

      while read -r ip_addr || [[ -n $ip_addr ]]; do
        status_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 3 "http://$ip_addr/healthcheck")
        if [[ $status_code == "200" ]]; then
          if [[ ! -z "$addr_str" ]]; then
            addr_str="$addr_str"$'\n'
            addr_str_grpc="$addr_str_grpc"$'\n'
          fi
          addr_str="$addr_str""    server $ip_addr;"
          addr_str_grpc="$addr_str_grpc""    server $ip_addr:9090;"

          is_healthy=true
        fi
      done < <(echo "$new_ips")

      if [[ "$is_healthy" == "false" ]]; then
        addr_str="    server 127.0.0.1:1;"
        addr_str_grpc="    server 127.0.0.1:1;"
      fi
    fi

    echo "upstream lb_$service_name {" >> $TMP_UPSTREAM_CONFIG_FILE
    echo "$addr_str" >> $TMP_UPSTREAM_CONFIG_FILE
    echo "}" >> $TMP_UPSTREAM_CONFIG_FILE

    echo "upstream lb_grpc_$service_name {" >> $TMP_UPSTREAM_CONFIG_FILE
    echo "$addr_str_grpc" >> $TMP_UPSTREAM_CONFIG_FILE
    echo "}" >> $TMP_UPSTREAM_CONFIG_FILE
  done
}

########################################################################################################################
# nginx

curl -s https://raw.githubusercontent.com/baabeetaa/cosmosia/main/proxy/nginx.conf > /etc/nginx/nginx.conf
curl -s https://raw.githubusercontent.com/baabeetaa/cosmosia/main/proxy/index.html > /usr/share/nginx/html/index.html

# generate new config file and copy to $UPSTREAM_CONFIG_FILE
generate_new_upstream_config
cat $TMP_UPSTREAM_CONFIG_FILE > $UPSTREAM_CONFIG_FILE

#/usr/sbin/nginx -g "daemon off;"
/usr/sbin/nginx
sleep 5

########################################################################################################################
# logrotate
sed -i -e "s/{.*/{\n\tdaily\n\trotate 2/" /etc/logrotate.d/nginx
sed -i -e "s/create.*/create 0644 root root/" /etc/logrotate.d/nginx


########################################################################################################################
# big loop

killall netdata
killall nginx
sleep 5
/usr/sbin/nginx
sleep 5
/opt/netdata/bin/srv/netdata


while true; do
  generate_new_upstream_config

  if cmp -s "$UPSTREAM_CONFIG_FILE" "$TMP_UPSTREAM_CONFIG_FILE"; then
    # the same => do nothing
    echo "no config change, do nothing..."
  else
    # different

    # show the diff
    diff -c "$UPSTREAM_CONFIG_FILE" "$TMP_UPSTREAM_CONFIG_FILE"

    echo "found config changes, updating..."
    cat $TMP_UPSTREAM_CONFIG_FILE > $UPSTREAM_CONFIG_FILE

    # need to use cron job for logrotate
    logrotate /etc/logrotate.d/nginx

    nginx -s reload
  fi

  # sleep 60 seconds...
  sleep 60
done
