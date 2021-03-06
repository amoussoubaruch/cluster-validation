#!/bin/bash
# jbenninghoff 2013-Jun-07  vi: set ai et sw=3 tabstop=3:

cat - << 'EOF'
# MapR rpc test to validate network bandwidth using cluster bisection strategy
# One half of the nodes act as clients by sending load to other half of the nodes acting as servers.
# The throughput between each pair of nodes is reported.
# When run concurrently (the default case), load is also applied to the network switch(s).
# Use -m option to run tests on multiple server NICs
# Use -s option to run tests in seqential mode
# Use -i option to run iperf test instead of rpctest
# Use -z option to specify size of test in MB (default==5000)
EOF
read -p "Press enter to continue or ctrl-c to abort"

concurrent=true; runiperf=false; multinic=false size=5000
while getopts ":simz:" opt; do
  case $opt in
    s) concurrent=false ;;
    i) runiperf=true ;;
    m) multinic=true ;;
    z) size=$OPTARG ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit ;;
  esac
done

scriptdir="$(cd "$(dirname "$0")"; pwd -P)" #absolute path to this script dir
iperfbin=iperf #Installed iperf version
iperfbin=iperf3 #Installed iperf3 {uses same options}
iperfbin=$scriptdir/iperf #Packaged version
rpctestbin=/opt/mapr/server/tools/rpctest #Installed version
rpctestbin=$scriptdir/rpctest #Packaged version
tmpfile=$(mktemp); trap 'rm $tmpfile' 0 1 2 3 15

#############################################################
if [ $multinic == "true" ]; then # Capture multiple NIC addrs on servers
   clush -aN hostname -I | sort -n > $tmpfile || { echo Unable to acquire IP addresses with clush, check clush config; exit 2; }
   hcount=$(cat $tmpfile | wc -l)
   multinics=($(sed -n "1,$(($hcount/2))s/ /,/p" $tmpfile)) #comma sep for rpctest
fi

# Generate the bash arrays with IP address values using clush
clush -aN hostname -i | sort -n > $tmpfile || { echo Unable to acquire IP addresses with clush, check clush config; exit 2; }
hcount=$(cat $tmpfile | wc -l)
half1=($(sed -n "1,$(($hcount/2))p" $tmpfile))
half2=($(sed -n "$(($hcount/2+1)),\$p" $tmpfile))
# Tar up any previous log files
tmp=${half2[@]}
clush -w ${tmp// /,} 'files=$(ls *-{rpctest,iperf}.log 2>/dev/null); [ -n "$files" ] && { tar czf network-tests-$(date "+%Y-%m-%dT%H-%M%z").tgz $files; rm -f $files; }'
if [ $(($hcount & 1)) -eq 1 ]; then 
   extraip=$(sed -n '$p' $tmpfile)
   echo Uneven IP address count, removing extra client IP
   sed -i '$d' $tmpfile
fi
hcount=$(cat $tmpfile | wc -l) #Redefine after $extraip removed
half2=($(sed -n "$(($hcount/2+1)),\$p" $tmpfile)) #Redefine after $extraip del

#############################################################
# Manually define array of server hosts (half of all hosts in cluster)
#  NOTE: use IP addresses to ensure specific NIC utilization
#half1=(10.10.100.165 10.10.100.166 10.10.100.167)

for node in "${half1[@]}"; do
  if [ $runiperf == "true" ]; then
     ssh -n $node "$iperfbin -s -i3 > /dev/null" &  # iperf alternative test, requires iperf binary pushed out to all nodes like rpctest
  else
     ssh -n $node $rpctestbin -server &
  fi
  #ssh $node 'echo $[4*1024] $[1024*1024] $[4*1024*1024] | tee /proc/sys/net/ipv4/tcp_wmem > /proc/sys/net/ipv4/tcp_rmem'
done
echo Servers have been launched
sleep 9 # let the servers stabilize

#############################################################
# Manually define 2nd array of client hosts (other half of all hosts in cluster)
#  NOTE: use IP addresses to ensure specific NIC utilization
#half2=(10.10.100.168 10.10.100.169 10.10.100.169)

i=0 # index into array
for node in "${half2[@]}"; do
  case $concurrent in #convert case block to if/else block
     true)
       if [ $runiperf == "true" ]; then
         #ssh -n $node "$iperfbin -c ${half1[$i]} -t 30 -w 16K > server-${half1[$i]}-iperf.log" & #16K socket buffer/window size MapR uses
         ssh -n $node "$iperfbin -c ${half1[$i]} -t 9 > server-${half1[$i]}-iperf.log" &  #Small initial test, increase -t value for better test
       else
         if [ $multinic == "true" ]; then
            ssh -n $node "$rpctestbin -client -b 32 $size ${multinics[$i]} > server-${half1[$i]}-rpctest.log" &
         else
            ssh -n $node "$rpctestbin -client -b 32 $size ${half1[$i]} > server-${half1[$i]}-rpctest.log" & #Small initial test, increase 5000 by 10x or 50x
         fi
       fi
       #catch all client PIDs ($!)
       clients="$clients $!"
       ;;
     false) #Sequential mode can be used to help isolate NIC and cable issues
       if [ $runiperf == "true" ]; then
         #ssh -n $node "$iperfbin -c ${half1[$i]} -t 30 -i3 -w 16K > server-${half1[$i]}-iperf.log" # 16K socket buffer/window size MapR uses
         ssh -n $node "$iperfbin -c ${half1[$i]} -t 9 -i3 > server-${half1[$i]}-iperf.log" # Small initial test, increase -t value for better test
       else
         if [ $multinic == "true" ]; then
            ssh -n $node "$rpctestbin -client -b 32 $size ${multinics[$i]} > server-${half1[$i]}-rpctest.log"
         else
            ssh -n $node "$rpctestbin -client -b 32 $size ${half1[$i]} > server-${half1[$i]}-rpctest.log"
         fi
       fi

       ssh $node "arp -na | awk '{print \$NF}' | sort -u | xargs -l ethtool | grep -e ^Settings -e Speed:"
       ssh $node "arp -na | awk '{print \$NF}' | sort -u | xargs -l ifconfig | grep errors"
       echo
       ;;
  esac
  ((i++))
  #ssh $node 'echo $[4*1024] $[1024*1024] $[4*1024*1024] | tee /proc/sys/net/ipv4/tcp_wmem > /proc/sys/net/ipv4/tcp_rmem'
done
[ $concurrent == "true" ] && echo Clients have been launched
[ $concurrent == "true" ] && { echo Waiting for PIDS: $clients; wait $clients; } #Wait for all clients to finish in concurrent run
sleep 5

# Handle the odd numbered node count (extra node)
if [ -n "$extraip" ]; then 
   ((i--)) #decrement to reuse last server in server list $half1
   if [ $runiperf == "true" ]; then
      ssh -n $extraip "$iperfbin -c ${half1[$i]} -t 9 > server-${half1[$i]}-iperf.log" #Small initial test, increase -t value for better test
   else
      ssh -n $extraip "$rpctestbin -client -b 32 $size ${half1[$i]} > server-${half1[$i]}-rpctest.log"
   fi
fi

# Define list of client nodes to collect results from
tmp=${half2[@]}
[ -n "$extraip" ] && tmp="$tmp $extraip"

echo
[ $concurrent == "true" ] && echo Concurrent network throughput results || echo Sequential network throughput results
if [ $runiperf == "true" ]; then
   clush -w ${tmp// /,} grep -i -h -e ^ \*-iperf.log # Print the measured bandwidth (string TBD)
   tmp=${half1[@]}
   clush -w ${tmp// /,} pkill iperf #Kill the servers
else
   clush -w ${tmp// /,} grep -i -H -e ^Rate -e error \*-rpctest.log #Print the network bandwidth (mb/s is MB/sec), 1GbE=125MB/s, 10GbE=1250MB/s
   tmp=${half1[@]}
   clush -w ${tmp// /,} pkill rpctest #Kill the servers
fi

# Unlike most Linux commands, option order is important for rpctest, -port must be used before other options
#[root@rhel1 ~]# /opt/mapr/server/tools/rpctest --help
#usage: rpctest [-port port (def:5555)] -server
#usage: rpctest [-port port (def:5555)] -client mb-to-xfer (prefix - to fetch, + for bi-dir) ip ip ip ...

