## Script to automate the startup of the ora5 EC2 instance and then reconfigure iSCSI to the newly deployed RedDotCBS1 Array
## Primaary reason for startup/shutdown is to avoid large AWS bill as there is currently no shutdown/hibernate feature for CBS
## Author: 	Danny Higgins 
## Date:	January 2020
## Version:     1.0
## Pre-reqs:	The RedDotCBS1 array must have been deployed using the deploy_cbs_json.bash script
## Issues:	
###################################################################################
## Variables
############
LOG=~/start_stop_ora5.log
FA_NAME=RedDotX
FA_IP="**REMOVED**"
FA_USER=pureuser
FA_PGROUP="ora5-RedDotCBS1"
FA_VOL_GROUP="vvol-ora5-d1ae08e4-vg"
CBS_NAME=RedDotCBS1
CBS_USER=pureuser
REP_LIMIT="50M"
REP_FS_LIST="/FRA /DATA /CONTROL_REDO"
START_INSTANCE="i-0eeab10b22770da6e"
S3_OFFLOAD="reddotcbs-snaptos3-offload-target"
SECRET_ACCESS_KEY="*****REMOVED*****"
ORA_HOST="**REMOVED**"
ORA_NAME="AWS-ora5"
ORA_IQN="iqn.1994-05.com.redhat:2d772262ee9d"
CURRENT_TIME=`date +%Y%m%d%H%M%S`
CURRENT_YEAR=`date +%Y`
SNAPNAME=SNAP${CURRENT_TIME}
SNAP_RETENTION_DAYS=3
REPLICATION_TIMEOUT_SECONDS=5000
REPLICATION_CHECK_INTERVAL=5


logme ()
{
echo "`date`: ${*}" | tee -a ${LOG}
}

check_cbs_stack ()
{
## Check there is a CBS stack deployed before continuing 
STACK_NAME=`aws --region ap-southeast-1 cloudformation list-stacks --stack-status-filter CREATE_COMPLETE --query "StackSummaries[*].StackName" --output text`
STACK_LENGTH=${#STACK_NAME}
if [ ${STACK_LENGTH} -lt 5 ] ; then
	logme "No CBS Stack found.... ABORTING"
	exit 1
fi

logme "CBS Stack found: ${STACK_NAME}"
logme "Querying CBS Stack ${STACK_NAME} to determine MGMT and iSCSI IP's"
# Find IP's of the newly deployed CBS instance
CBS_ISCSI_CT0=`aws cloudformation --region ap-southeast-1 describe-stacks --stack-name ${STACK_NAME} --query "Stacks[0].Outputs[?OutputKey=='iSCSIEndpointCT0'].OutputValue" --output text`
CBS_ISCSI_CT0_IP=`echo ${CBS_ISCSI_CT0} | cut -f1 -d":"`
logme "${CBS_NAME} iSCSI CTO IP is: ${CBS_ISCSI_CT0_IP}"

CBS_ISCSI_CT1=`aws cloudformation --region ap-southeast-1 describe-stacks --stack-name ${STACK_NAME} --query "Stacks[0].Outputs[?OutputKey=='iSCSIEndpointCT1'].OutputValue" --output text`
CBS_ISCSI_CT1_IP=`echo ${CBS_ISCSI_CT1} | cut -f1 -d":"`
logme "${CBS_NAME} iSCSI CT1 IP is: ${CBS_ISCSI_CT1_IP}"

CBS_MGMT_IP=`aws cloudformation --region ap-southeast-1 describe-stacks --stack-name ${STACK_NAME} --query "Stacks[0].Outputs[?OutputKey=='ManagementEndpoint'].OutputValue" --output text`
logme "${CBS_NAME} Management IP is: ${CBS_MGMT_IP}"
}

## Startup Oracle Host

start_ec2 ()
{
logme "About to start the ${ORA_NAME} EC2 instance"
aws --region ap-southeast-1 ec2 start-instances --instance-ids ${START_INSTANCE}  | tee -a ${LOG}

logme "Sleeping for 180 seconds to allow EC2 instance to startup"
for i in {1..180}
do
        echo -n "${i} "
        sleep 1
done
}


# Now load the ec2 public key onto the RedDotCBS1 instance so we can create the volumes/hosts etc.
# Note: A bug in the CBS beta2 code prevents an ssh public key from being loaded onto the array. We are using the following sshpass woarkaround instead.

#ssh pureuser@${CBS_MGMT_IP} 
run_cbs ()
{
sshpass -p pureuser ssh -q -o StrictHostKeyChecking=no pureuser@${CBS_MGMT_IP} ${*}
}

run_fa ()
{
sshpass -p pureuser ssh -q -o StrictHostKeyChecking=no pureuser@${FA_IP} ${*}
}

create_connect_vols ()
{
run_cbs "purevgroup create ${FA_VOL_GROUP}"
run_cbs "purevol create --size 5G CONTROL_REDO"
run_cbs "purevol create --size 15G DATA"
run_cbs "purevol create --size 30G FRA"
run_cbs "purehost create --iqnlist ${ORA_IQN} ${ORA_NAME}"
run_cbs "purehost connect --vol CONTROL_REDO ${ORA_NAME}"
run_cbs "purehost connect --vol DATA ${ORA_NAME}"
run_cbs "purehost connect --vol FRA ${ORA_NAME}"
run_cbs "purevol move CONTROL_REDO ${FA_VOL_GROUP}"
run_cbs "purevol move DATA ${FA_VOL_GROUP}"
run_cbs "purevol move FRA ${FA_VOL_GROUP}"
}

connect_cbs_s3 ()
{
echo "${SECRET_ACCESS_KEY}
${SECRET_ACCESS_KEY}
" | run_cbs "pureoffload s3 connect --access-key-id ***REMOVED*** --bucket ${S3_OFFLOAD} reddotcbs-offload-target"

logme "Sleeping for 5 seconds to allow offload connection to complete"
for i in {1..5}
do
        echo -n "${i} "
        sleep 1
done
}

setup_ora_pg ()
{
run_cbs "purepgroup create --hostlist ${ORA_NAME} --targetlist reddotcbs-offload-target ${ORA_NAME}-PG"
#run_cbs "purepgroup schedule --replicate-frequency 4h ${ORA_NAME}-PG"
#run_cbs "purepgroup retain --per-day 4 --all-for 1d --days 7 --target-per-day 1 --target-all-for 1d --target-days 90 ${ORA_NAME}-PG"
run_cbs "purepgroup enable --replicate ${ORA_NAME}-PG"
}

connect_fa_cbs ()
{
logme "Setting up Async replication from ${FA_NAME} to ${CBS_NAME}"	
CBS_CON_KEY=`run_cbs "purearray list --connection-key" | tail -1`
logme "Connection key from ${CBS_NAME} is ${CBS_CON_KEY}"
logme "Calling ${FA_NAME} to initiate Async Replication"
echo ${CBS_CON_KEY} | run_fa "purearray connect --management-address ${CBS_MGMT_IP} --type async-replication --connection-key" | tee -a ${LOG}
logme "Trottling replication link to ${REP_LIMIT}B/s so we don't saturate SG office 1Gb network"
run_fa "purearray throttle --connect --default-limit ${REP_LIMIT} ${CBS_NAME}"
}

# Login to the ${ORA_NAME} instance and reconfigure iSCSI accordingly (Requires ssh key passwordless access to ${ORA_NAME})

#RUN_ORA1="ssh -i /home/ec2-user/pureuser.pem clckwrk@${ORA_HOST}"

run_ora ()
{
ssh -i /home/ec2-user/pureuser.pem ec2-user@${ORA_HOST} ${*}
}

reconfig_iscssi ()
{
run_ora "sudo id;hostname"
logme "Stopping iSCSSI on ${ORA_HOST}"
run_ora "sudo service iscsi stop" | tee -a $LOG
sleep 1
logme "Removing old config files from /var/lib/iscsi"
run_ora "sudo  -- sh -c 'cd /var/lib/iscsi/nodes ; rm -rf iqn.*'"
run_ora "sudo  -- sh -c 'cd /var/lib/iscsi/send_targets ; rm -rf 10.226.*'"
sleep 1
logme "Discovering iSCSSI targets on ${CBS_ISCSI_CT0_IP} & ${CBS_ISCSI_CT1_IP}"
run_ora "sudo iscsiadm -m discovery -t st -p ${CBS_ISCSI_CT0_IP}" | sort -u > cbs_isci_targets.txt
sleep 1
run_ora "sudo iscsiadm -m discovery -t st -p ${CBS_ISCSI_CT1_IP}" | sort -u >> cbs_isci_targets.txt
sleep 1
logme "Starting iSCSSi service:"
run_ora "sudo service iscsi start" | tee -a $LOG
sleep 1
PURE_IQN=`cat cbs_isci_targets.txt | cut -f2 -d" " | sort -u`
logme "Logging into discovered iSCSI targets"
for i in iscsi0 iscsi1
do
	run_ora "sudo iscsiadm -m node --targetname ${PURE_IQN} -I ${i} -p ${CBS_ISCSI_CT0_IP} --login"
	run_ora "sudo iscsiadm -m node --targetname ${PURE_IQN} -I ${i} -p ${CBS_ISCSI_CT1_IP} --login"
done
sleep 1
run_ora "sudo iscsiadm -m node -L automatic"
sleep 1
logme "Enabling multipathing:"
run_ora "sudo mpathconf --enable --with_multipathd y"
sleep 1
}

replicate ()
{
logme "About to replicate snaphot of ${FA_NAME} DB protection group using the following command"
logme "purepgroup snap --suffix ${SNAPNAME} --replicate-now ${FA_PGROUP}"
run_fa "purepgroup setattr --targetlist ${CBS_NAME} ${FA_PGROUP}"
run_fa "purepgroup snap --replicate-now --suffix ${SNAPNAME} ${FA_PGROUP}"
}

check_rep_status ()
{
> ora_snaps.log
REP_TIMER=0
while ! grep "Completed=$CURRENT_YEAR" ora_snaps.log
do
	run_fa "purepgroup list --nvp --transfer --snap ${FA_PGROUP}.${SNAPNAME}" > ora_snaps.log
	echo -n "${REP_TIMER} "
 	sleep ${REPLICATION_CHECK_INTERVAL}
 	REP_TIMER=$((${REP_TIMER} + ${REPLICATION_CHECK_INTERVAL}))
	if [ ${REP_TIMER} -gt ${REPLICATION_TIMEOUT_SECONDS} ]
	then
        	logme "ERROR: Replication duration has exceeded the defined timout of ${REPLICATION_TIMEOUT_SECONDS} seconds... ABORTING"
		exit 6
	fi
done
grep ora_snaps.log ora_snaps.log | tee -a ${LOG}
}

refresh_vol ()
{
run_cbs "purevol copy --overwrite "${FA_NAME}:${FA_PGROUP}.${SNAPNAME}.vvol-ora5-d1ae08e4-vg/Data-003c6423 ${FA_VOL_GROUP}/CONTROL_REDO""
run_cbs "purevol copy --overwrite "${FA_NAME}:${FA_PGROUP}.${SNAPNAME}.vvol-ora5-d1ae08e4-vg/Data-663ef8b5 ${FA_VOL_GROUP}/DATA""
run_cbs "purevol copy --overwrite "${FA_NAME}:${FA_PGROUP}.${SNAPNAME}.vvol-ora5-d1ae08e4-vg/Data-fe42bf7b ${FA_VOL_GROUP}/FRA""
}


mount_fs ()
{
# Mount /dev/mapper devices matched to LUN serial numbers
> mount_ora.sh
run_ora "sudo ls /dev/mapper" > devices.txt
run_cbs "purevol list --filter \"name = '*${FA_VOL_GROUP}*'\" --csv --notitle" > purevols.txt
IFS=,
while read -r VOLNAME B C D SERIAL
do
	#echo "Volume is: ${VOLNAME} Serial is: ${SERIAL}"
	MPOINT=`echo ${VOLNAME} | cut -f2 -d"/"`
	SERIAL2="${SERIAL/$'\r'/}"
	MPATH=`cat devices.txt | egrep -i ${SERIAL2}`
	logme "Mounting /dev/mapper/${MPATH} on /${MPOINT}"
	#run_ora "sudo mount /dev/mapper/${MPATH} /${MPOINT}"
	#run_ora "sudo chown -R oracle:oinstall /${MPOINT}"
	echo "sudo mount /dev/mapper/${MPATH} /${MPOINT}" >> mount_ora.sh
	echo "sudo chown -R oracle:oinstall /${MPOINT}" >> mount_ora.sh
done < purevols.txt > mount.log
unset IFS
cat mount_ora.sh | run_ora
}

unmount_fs ()
{
for FS in ${REP_FS_LIST}
do
	logme "Unmounting ${FS}"
	run_ora "sudo umount -f ${FS}"
done
}


create_asm_disks ()
{
# Configure ASMLib with /dev/mapper devices matched to LUN serial numbers
run_ora "sudo ls /dev/mapper/*" > devices.txt
run_cbs "purevol list --csv --notitle" > purevols.txt
IFS=,
while read -r VOLNAME B C D SERIAL
do
	#echo "Volume is: ${VOLNAME} Serial is: ${SERIAL}"
	SERIAL2="${SERIAL/$'\r'/}"
	MPATH=`cat devices.txt | egrep -i ${SERIAL2}`
	echo "oracleasm createdisk ${VOLNAME} ${MPATH}"
	ASM_CMD="sudo oracleasm createdisk ${VOLNAME} ${MPATH}"
#	run_ora ${ASM_CMD}
done < purevols.txt > asm_create_disks.txt
unset IFS
}

start_ora ()
{
logme "Starting Oracle Database and Listener"
run_ora "sudo -i -u oracle /home/oracle/start_ora.bash" | tee -a ${LOG}
}

stop_ora ()
{
logme "Stopping Oracle Database and Listener"
run_ora "sudo -i -u oracle /home/oracle/stop_ora.bash" | tee -a ${LOG}
}

purge_snaps ()
{
logme "Purging the snapshots from the source array ${FA_NAME}"
} 

disconnect_fa_cbs ()
{
logme "Disconnecting replication connection from ${FA_NAME} to ${CBS_NAME}"
run_fa "purearray disconnect ${CBS_NAME}" | tee -a ${LOG}
}

disconnect_cbs_s3 ()
{
logme "Disconnecting replication connection from ${CBS_NAME} to ${S3_OFFLOAD}"
run_cbs "pureoffload s3 disconnect reddotcbs-offload-target" |  tee -a ${LOG}
}

cleanup_working_files ()
{
rm mount_ora.sh
rm mount.log
rm devices.txt
rm purevols.txt
rm ora_snaps.log
rm cbs_isci_targets.txt
}

# Overwrite database volumes from snaps

##################
## MAIN PROGRAM ##
##################

if [ ${#} -eq 1 ]
then
	case ${1} in
	start)	
	     logme "----------------------------------------------------"
	     logme "STARTING AWS ORA5 STARTUP AND CLONE SCRIPT ---------"
	     logme "----------------------------------------------------"
	     check_cbs_stack
	     start_ec2
	     create_connect_vols
	     connect_fa_cbs
	     replicate
	     check_rep_status
	     refresh_vol
	     reconfig_iscssi
	     mount_fs
	     connect_cbs_s3
	     setup_ora_pg
	     start_ora
	     cleanup_working_files
	     logme "----------------------------------------------------"
	     logme "FINISHED AWS ORA5 STARTUP AND CLONE SCRIPT ---------"
	     logme "----------------------------------------------------";;
	stop)
	     #offload_s3
	     sleep 10
	     stop_ora 
	     unmount_fs
	     disconnect_fa_cbs
	     disconnect_cbs_s3;;
	refresh)
	     logme "----------------------------------------------------"
	     logme "FINISHED AWS ORA5 REFREH SCRIPT --------------------"
	     logme "----------------------------------------------------"
	     check_cbs_stack
	     stop_ora
	     unmount_fs
	     replicate
	     check_rep_status
	     refresh_vol
	     mount_fs
	     start_ora
	     logme "----------------------------------------------------"
	     logme "FINISHED AWS ORA5 REFREH SCRIPT --------------------"
	     logme "----------------------------------------------------";;
	*) 
	     echo "Error: USAGE: start_stop_ora5.bash start|stop|refresh"
	     echo "          OR: start_stop_ora5.bash function start_ec2|create_connect_vols|connect_fa_cbs|replicate|check_rep_status|refresh_vol|reconfig_iscssi|mount_fs|connect_cbs_s3|setup_ora_pg|start_ora|cleanup_working_files|stop_ora|unmount_fs|disconnect_fa_cbs|disconnect_cbs_s3";;	
	esac
elif [ ${#} -eq 2 ]
then
	if [ ${1} = "function" ]
	then 
	case ${2} in
		start_ec2)
			start_ec2;;
		create_connect_vols)
			create_connect_vols;;
		connect_fa_cbs)
			connect_fa_cbs;;
		replicate)
			replicate;;
		check_rep_status)
			check_rep_status;;
		refresh_vol)
			refresh_vol;;
		reconfig_iscssi)
			reconfig_iscssi;;
		mount_fs)
			mount_fs;;
		connect_cbs_s3)
			connect_cbs_s3;;
		setup_ora_pg)
			setup_ora_pg;;
		start_ora)
			start_ora;;
		cleanup_working_files)
			cleanup_working_files;;
		stop_ora)
			stop_ora;;
		unmount_fs)
			unmount_fs;;
		disconnect_fa_cbs)
			disconnect_fa_cbs;;
		disconnect_cbs_s3)
			disconnect_cbs_s3;;
		*) 
	     		echo "Error: USAGE: ${0} start|stop|refresh"
	     		echo "          OR: ${0} function start_ec2|create_connect_vols|connect_fa_cbs|replicate|check_rep_status|refresh_vol|reconfig_iscssi|mount_fs|connect_cbs_s3|setup_ora_pg|start_ora|cleanup_working_files|stop_ora|unmount_fs|disconnect_fa_cbs|disconnect_cbs_s3";;	
	esac
	fi
else
	echo "ERROR: USAGE: ${0} start|stop|refresh|function"
fi
