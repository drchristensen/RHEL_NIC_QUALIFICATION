#!/bin/bash

# Uncomment to enable debugging
# set -xv

# Converts a range of CPUs into an array.
# For example, "0-3,7" becomes "0,1,2,3,7".
# Requires two arguments:
# $1 - The string to be expanded
# $2 - The list of CPUs being returned
function parse_range {
	arr=()
  IFS=', ' read -a ranges <<< $1
  for range in "${ranges[@]}"; do
    IFS=- read start end <<< "$range"
    [ -z "$start" ] && continue
    [ -z "$end" ] && end=$start
    for ((i = start; i <= end; i++)); do
			arr+=($i)
    done
  done
  eval $2=$(IFS=,;printf "%s" "${arr[*]}")
}

# Compacts an array of CPUs into a range.
# For example, "0,1,2,3,7" becomes "0-3,7".
# Requires two arguments:
# $1 - The string to be compacted
# $2 - The list of CPUs being returned
function compact_range {
	arr=()
	start=""
	for cpu in ${1//,/ }; do
		[ -z "$start" ] && start=$cpu && range=$cpu && last=$cpu && continue
		prev=$(( $cpu - 1 ))
		[ "$prev" -ne "$last" ] && arr+=($range) && start=$cpu && range=$cpu && last=$cpu && continue
		range="${start}-${cpu}" && last=$cpu
	done
	arr+=($range)
  eval $2=$(IFS=,;printf "%s" "${arr[*]}")
}

dev_pci=$1
func_name=$2

if [ x"$dev_pci" == x"" ]
then
	exit 1
fi

if [ x"$func_name" == x"" ]
then
	exit 1
fi

if ! lspci -D | grep $dev_pci &> /dev/null
then
	exit 1
fi

nofunc=1
for name in dut_isolated_cpus dut_dpdk_pmd_mask dut_pmd_rxq_affinity vcpu_0 vcpu_1 vcpu_2 vcpu_3 vcpu_4 vcpu_5 vcpu_6 vcpu_7 dut_dpdk_lcore_mask vcpu_str vcpu_emulator vcpu_count
do
	if [ $func_name == $name ]
	then
		nofunc=0
		break
	fi
done

if [ $nofunc -eq 1 ]
then
	exit 1
fi

threads_per_core=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
# cores_per_socket=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')

# Calculate the number of CPUs required for the test.  x86 systems typically
# support two threads per core while Power systems can support between two and
# eight threads per core.
required_numa_count=2
let required_vcpu_count="2 * $threads_per_core"
let required_cpu_count="1 + $threads_per_core + $required_vcpu_count"

# Identify the NUMA node associated with the given PCI device
# along with another NUMA node not associated with the device
dev_numa_node1=$(lspci  -s $dev_pci -v | grep -o "NUMA node [0-9]*" | awk '{print $3}')
dev_numa_node2=$(lscpu | grep "NUMA node.*CPU" | grep -v "NUMA node${dev_numa_node1}" | head -n 1 | sed -E 's/^NUMA node([0-9]*).*/\1/g')

# Obtain a list of CPUs associated with each NUMA node,
parse_range $(lscpu | grep "NUMA node${dev_numa_node1}" | awk '{print $4}') numa_cpu_list1
parse_range $(lscpu | grep "NUMA node${dev_numa_node2}" | awk '{print $4}') numa_cpu_list2

# Gather a list of CPU siblings for the first CPU of the given NUMA node
num=$(echo $numa_cpu_list1 | awk -F, '{print $1}')
parse_range $(cat /sys/devices/system/cpu/cpu${num}/topology/thread_siblings_list) host_cpus_list1
num=$(echo $numa_cpu_list2 | awk -F, '{print $1}')
parse_range $(cat /sys/devices/system/cpu/cpu${num}/topology/thread_siblings_list) host_cpus_list2

# Reserve the first CPU and its siblings for host OS use
dut_isolated_cpus=$numa_cpu_list1
for cpu in ${host_cpus_list1//,/ }; do
	dut_isolated_cpus=$(echo $dut_isolated_cpus | sed "s/^$cpu,//g" | sed "s/,$cpu,/,/g")
done

# Pick the first free CPU in the DUT isolated list, along with its thread siblings, and
# assign it to the OVS/DPDK PMD running on the DUT
num=$(echo $dut_isolated_cpus | awk -F, '{print $1}')
parse_range $(cat /sys/devices/system/cpu/cpu${num}/topology/thread_siblings_list) pmd_siblings_list

# Create another list of the remaining, isolated CPUs
remaining_cpus=$dut_isolated_cpus
for cpu in ${pmd_siblings_list//,/ }; do
	remaining_cpus=$(echo $remaining_cpus | sed "s/^$cpu,//g" | sed "s/,$cpu,/,/g")
done

# Count the number of DUT isolated CPUs and make sure there are enough
# to assign for all requirements
dut_isolated_cpus_count=$(echo $dut_isolated_cpus | awk -F, '{print NF}')
if [ $dut_isolated_cpus_count -lt $required_cpu_count ]; then
	exit 1
fi

# Count the number of NUMA nodes and make sure there are enough to run the test
numa_node_count=$(lscpu | grep "NUMA node(s)" | awk '{print $3}')
if [ $numa_node_count -lt $required_numa_count ]; then
	exit 1
fi

dut_isolated_cpus()
{
	local isolated_cpus=""
	compact_range $dut_isolated_cpus isolated_cpus
	echo $isolated_cpus
}

dut_dpdk_pmd_mask()
{
	hex_string=""
	for cpu in ${pmd_siblings_list//,/ }; do
		hex_string="${hex_string}1<<${cpu}|"
	done
	hex_string="${hex_string}0"
	# ToDo: Need to handle python2?
	echo `python3 -c "print(hex($hex_string))"`
}

dut_pmd_rxq_affinity()
{
	res=$(i=0; for t in ${pmd_siblings_list//,/ }; do printf "${i}:${t},"; let i++; done | sed 's/,$//')
	echo $res
}

vcpu_count()
{
	echo $required_vcpu_count
}

vcpu_str()
{
	local vcpu_str=""
	res=$(i=1; for t in ${remaining_cpus//,/ }; do printf "${t},"; if [ $i -ge $required_vcpu_count ]; then break; fi; let i++; done | sed 's/,$//')
	compact_range $res vcpu_str
	echo $vcpu_str
}

vcpu_0()
{
	echo $remaining_cpus | awk -F, '{print $1}'
}

vcpu_1()
{
	echo $remaining_cpus | awk -F, '{print $2}'
}

vcpu_2()
{
	echo $remaining_cpus | awk -F, '{print $3}'
}

vcpu_3()
{
	echo $remaining_cpus | awk -F, '{print $4}'
}

vcpu_4()
{
	if [ $threads_per_core -eq 4 ]; then
		echo $remaining_cpus | awk -F, '{print $5}'
	else
		exit 1
	fi
}

vcpu_5()
{
	if [ $threads_per_core -eq 4 ]; then
		echo $remaining_cpus | awk -F, '{print $6}'
	else
		exit 1
	fi
}

vcpu_6()
{
	if [ $threads_per_core -eq 4 ]; then
		echo $remaining_cpus | awk -F, '{print $7}'
	else
		exit 1
	fi
}

vcpu_7()
{
	if [ $threads_per_core -eq 4 ]; then
		echo $remaining_cpus | awk -F, '{print $8}'
	else
		exit 1
	fi
}

vcpu_emulator()
{
	if [ $threads_per_core -eq 2 ]; then
		echo $remaining_cpus | awk -F, '{print $5}'
	elif [ $threads_per_core -eq 4 ]; then
		echo $remaining_cpus | awk -F, '{print $9}'
	else
		exit 1
	fi
}

dut_dpdk_lcore_mask()
{
	# Use CPUs on the other NUMA node
	hex_string=""
	for cpu in ${host_cpus_list2//,/ }; do
		hex_string="${hex_string}1<<${cpu}|"
	done
	hex_string="${hex_string}0"
	echo `python3 -c "print(hex($hex_string))"`
}

$func_name
