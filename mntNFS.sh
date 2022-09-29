#!/bin/bash
#
# This program is free software. It comes without any warranty, to
# the extent permitted by applicable law. You can redistribute it
# and/or modify it under the terms of the "Do What The Fuck You Want To"
# Public License, Version 2, December 2004, as published by Sam Hocevar.
# See http://sam.zoy.org/wtfpl/COPYING for more details.
# or https://en.wikipedia.org/wiki/WTFPL

# Authors: Huw Hamer Powell <huw@huwpowell.com>
# Purpose: Check if there are NFS Servers in your network and mount shares from them
# If a share is already mounted prompt and Unmount it if it is already mounted.
#	The mount point is created and destroyed after use (to prevent
#	automatic backup software to backup in the directory if the device
#	is not mounted)

# Version 3, enhanced for Ubuntu 13.X+, Fedora 35+, and similar distros.
# Runs on all GNU/Linux distros (install cifs-utils)

# Version 4, Crafted a mod for FC32+ and added some visible interactions using zenity/yad ..Else silent
# Added the use of zenity/yad to produce dialog in Gnome

# version 5, Cloned from mntSMB and Modified to use NFS
# Added proper mount options to cope with NFS and x display icons for mounted drives
# Runs on all GNU/Linux distros 
# Fedora/UBUNTU/Debian needs arp-scan, nmap and nc (apt/dnf]  install arp-scan nmap netcat)

#  1) Install  arp-scan and netcat (sudo [dnf apt] install arp-scan netcat)
#  2)If you want to use the full functionality of nice dialog boxes install yad . otherwise we default to zenity *not so nice but it works)
#  3) Change the first three variables according to your configuration. Or maintain a .ini file with the four variables. Can be created by the script if neccessary
#  4) Run this program at boot or from your $HOME  when your network is ready
#	(need to use sudo.. so run the skeleton script mntNFS which will call this script (mntNFS.sh) using sudo... Or from the CLI or Gnome Desktop 
#		   Also, run it on logoff to umount any mounted shares (Will remove the mount point directory). Does not matter if you don't , Just cleaner if you do :)
#
#------ Edit these four DEFAULT options to match your system. Alternatinvely create the $0.ini file and edit that instead and save the .ini file for next time
NFS_IP="10.0.1.200"					# e.g. "192.168.1.100"
NFS_VOLUME="10.0.0.200:/mnt/BigDisk"		# Whatever you named the NFS share"
#------
NFS_MOUNT_POINT=/media					# Base folder for mounting (/media recommended but could be /mnt or other choice)

TIMEOUTDELAY=5						# timeout for dialogs and messages. (in seconds)
YADTIMEOUTDELAY=$(($TIMEOUTDELAY*4))			# Extra time for completing the initial form and where necessary
NC_PORT=2049						# Which port to use to connect during scanning

######## !!!!!!!!!!!!!! DON'T MODIFY ANYTHING BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING !!!!!!!!!!!!!! ##########
######## !!!!!!!!!!!!!! DON'T MODIFY ANYTHING BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING !!!!!!!!!!!!!! ##########
#
#------------------------ Functions -------------------------------------------------------

#------ yad test -------------- Not used in this script.. It is Just a testbed

function yad-test () {

OUT=$(yad --on-top  --center --window-icon $YAD_ICON --image $YAD_ICON --geometry=800x800\
	--center --on-top --close-on-unfocus --skip-taskbar --align=right --text-align=center --buttons-layout=spread --borders=25 \
	--separator="," \
	--list --radiolist \
       	--columns=4 \
      	--title "Select Share" \
	--button="Select":2  \
	--button="Cancel":1 \
	--column "Sel" \
	--column "Server" \
	--column "Share" \
	--column "Comment" \
      	True "List contents of your Documents Folder" 'ls $HOME/Documents' "comment"\
      	False "List contents of your Downloads folder" 'ls $HOME/Downloads' "Comment" \
      	False "List contents of your Videos folder" 'ls $HOME/Videos' "Comment"
	)	
	if [ $? = "1" ]
		then exit
	fi
	
	OUT=$(echo "$OUT" \
	| cut -d "|" -s -f2,3 \
	| paste -s -d"|" \
	)
	echo "" \
	echo "The output from Yad is  '$OUT'" \
	; echo ""

	}
#------ end yad test -----------
#-------------save-vars-----------
function save-vars() {
# Save the defaults into the .ini or .last file

if [ -z $1 ]; then					# Checks if any params.
	VAREXTN="ini"					# default extension is .ini
else
	VAREXTN="$1"					# Take the extension from the arguments
fi

echo "# This file contains the variables to match your system and is included into the main script at runtime">$NFS_PNAME.$VAREXTN	# create the file
echo "# if this file does not exist you will get the option to create it from the defaults in the main script">>$NFS_PNAME.$VAREXTN
echo "">>$NFS_PNAME.$VAREXTN

echo 'NFS_IP="'"$NFS_IP"'"		# e.g. 192.168.1.100' >>$NFS_PNAME.$VAREXTN
echo 'NFS_VOLUME="'"$NFS_VOLUME"'"	# Whatever you named the Volume share' >>$NFS_PNAME.$VAREXTN
echo 'NFS_MOUNT_POINT="'"$NFS_MOUNT_POINT"'"	# Base folder for mounting (/media recommended but could be /mnt or other choice)' >>$NFS_PNAME.$VAREXTN
echo "">>$NFS_PNAME.$VAREXTN
echo "#-- Created `date` by `whoami` ----">>$NFS_PNAME.$VAREXTN
} # NOTE : The user name is not saved (commented out) to enable the hostname to be set next time around. Uncomment the line in the .ini file if a specific user name is required

#-------------END save-vars-----------
#------------ show-progress -------------
# A function to show a progress countdown for a command that might not be intantanious (Return the output from that command in the temp file $SPtmp_out
function show-progress() {

# args == $1="DialogTitle", $2="Text to display", $3="command to execute"
# Accept an agrument of a command to execute and wrap the progress bar around it
# open tmp file to accept the output from the command
# use zenity progress bar to execute command with progress bar, close progress bar when complete
# read output from the command and return to the caller in the var $SP_RTN
	
	SPtmp_out=$(mktemp --tmpdir `basename $0`.XXXXXXX)			# Somewhere to store any error message or output *(zenity/yad eats any return codes from any command)
	
	bash -c "$3 2>&1" \
	| tee $SPtmp_out \
	| zenity --progress --pulsate --auto-close --no-cancel --title="$1" --text="$2"

	SP_RTN=$(cat $SPtmp_out) 							# Read any error message or output from command ($3) from the tmp file 
	rm -f $SPtmp_out								# delete temp file after reading content
} 											# return the output from the command in the variable  $SP_RTN	

# --------------- unmount -------------------
# ---------- umount and trap any error message

function unmount() {
		show-progress "unMounting" "Attempting to unmount $1" "umount '$1'"

		ERR=$(echo "$SP_RTN")							# Read any error message

# --- end umount (any error message is in $ERR
		
		if [ -z "$ERR" ] ; then
			UNMOUNT_ERR=false						#Sucess
			
			if [ "$1" != "$MOUNT_POINT_ROOT" ]; then		# Dont remove the mount root is mount point is not set correcly
				rmdir "$1"					# Happened during testing DUHHH
			fi

			zenity	--warning --no-wrap \
			--title="Unmounted Volume" \
			--text="$1\nVolume was previously mounted.... Unmounted it!!  " \
			--timeout=1							# sucess message timeout 1 second
			
		else									# unmount failed
			UNMOUNT_ERR=true

			zenity	--error --no-wrap \
			--title="$1\nVolume is STILL Mounted" \
			--text="Something went wrong!!...  \n\n $ERR \n\nFailed to umount Volume $1 try again  " \
			--timeout=$TIMEOUTDELAY
		fi 									
	
	}
# -------------- END unmount ----------------
#---------------- set-netbiosname -------------
#Return the machine name from the volume string passed eg (192.168.1.106:/mnt/HD/HD_a2/huw)

function set-netbiosname() {
	SNM_IP=$(echo $1 | cut -d":" -s -f1)	# get the IP address from the volume string

	if [ -z "$SNM_IP" ]; then SNM_IP="$1"; fi	# if that didnt work we where given the IP address anyway

	NFS_NETBIOSNAME=$(echo "$NFS_SERVERS_AND_NAMES" \
		|grep -iw $SNM_IP \
		|awk '{$1 = ""; print $0;}' \
		|sed 's/\t//' \
		)		#1. Find the NETBIOS name "|sed 's/\t//' removes any tab characters, awk '{$2 = ""; print $0;}' print everything EXCEPT the first field *Dropping the IP address from the output 
	NFS_LASTSERVERONLINE=true
	if [ -z "$NFS_NETBIOSNAME" ]; then
		NFS_NETBIOSNAME="<span foreground='red'>*OFFLINE*</span>"  				# If name not found, it is probably offline
		NFS_LASTSERVERONLINE=false								# Show it as offline
	fi
}
# -------------- END set-netbiosname -------
#--------------- select-mounted -------------
function select-mounted() {
	M_PROCEED=''
# Find out what is currently mounted
	show-progress "Initializing" "Finding mounted Shares" "mount"												# find out what NFS shares are currently mounted
													# Parse a list of IP addresses and mount points
	MOUNTED_VOLS=$(echo "$SP_RTN" \
		|grep -w nfs \
		|grep -v sunrpc \
		|sort \
		|sed 's+ on /+\t/+g' \
		|sed 's+ /+\t/+g' \
		|awk 'BEGIN{FS=" type nfs ";OFS=""} {print $1;} '  \
		|awk 'BEGIN{FS="\t";OFS=""} {print "FALSE\n",$1,"\n",$2;} '				# make 3 columns (FALSE MountedVol MOUNTPOINT)
		)
# if anything is mounted  $MOUNTED_VOLS now looks like this
#FALSE
#192.168.1.106:/mnt/HD/HD_a2/Music
#/media/mntNFS/Music
#FALSE
#192.168.1.106:/mnt/HD/HD_a2/Public
#/media/mntNFS/Public
# 
# every field on seperate lines

	if [ -n "$MOUNTED_VOLS" ]									# if anything is mounted
	then
		OUT=$(yad --list --geometry=700x500 --separator="|" --center --on-top --close-on-unfocus --skip-taskbar --align=right --text-align=center --buttons-layout=spread --borders=25 \
		       		--window-icon $YAD_ICON --image $YAD_ICON \
				--checklist \
				--multiple \
				--title="Mounted NFS Volumes" \
				--text="<span><b><big><big>Currently Mounted Volumes\n\n</big>Select Any that you need to UnMount\nOr just Proceed to the mount option</big></b></span>\n" \
				--columns=3 \
				--column="Sel" \
				--column="Share" \
				--column="MountPoint" \
				--button="uMount Selected":2 \
				--button="Proceed":3 \
				<<< "$MOUNTED_VOLS"
		)

		if [ -n "$OUT" ]						# if anything was selected
			then 
			VOLS2UMOUNT=$(echo "$OUT" \
			| awk 'BEGIN{FS="|";OFS=""} {print $3;} '  \
			)							# Select the third field 'the mount point' from each selected item
			while IFS= read -r VOL; do
				unmount "$VOL"					# Unmount the selected volume(s)
				M_PROCEED='no'					# force us to be called again
										# if anything is unmounted
			done <<<$VOLS2UMOUNT
		fi								# endif anything selected for unmount

	fi									# endif anything mounted
}
# ------------ END select-mounted --------
#------------- scan-subnets --------------
# We scan subnets with nmap. This is slower than arp-scan and could take 30-40 seconds per subnet
function scan-subnets() {

# look for subnets file

	if [ -f $NFS_PNAME.subnets ]; then
		SCAN_SUBNETS=$(cat $NFS_PNAME.subnets |grep -v $NFS_SUBNET|sort -u ) # remove any current entry for this subnet and select only unique lines (No duplicates)
	fi

	if [ -n "$SCAN_SUBNETS" ]; then
		if [ -z "$NFS_SERVERS_AND_NAMES" ]; then
			SCAN_KNOWN_SERVERS="None"
		else
			SCAN_KNOWN_SERVERS=$NFS_SERVERS_AND_NAMES
		fi
		SCAN_SUBNETS=$(awk 'BEGIN{FS="\n";OFS=""} {print "FALSE\n",$1 ;} '<<<$SCAN_SUBNETS)

		OUT=$(yad --list --geometry=500x500 --separator="|" --on-top --close-on-unfocus --skip-taskbar --align=right --text-align=center --buttons-layout=spread --borders=25 \
			--window-icon $YAD_ICON --image $YAD_ICON \
			--checklist \
			--multiple \
			--title="Subnets to Scan" \
			--text="<span><b><big><big>Contents of $NFS_PNAME.subnets\n\n</big>Select Any that you want to Scan\nthen Proceed to scan selected Subnets</big></b></span>\n\nWe can already see these servers\n$SCAN_KNOWN_SERVERS\n" \
			--columns=2 \
			--column="Sel" \
			--column="Subnet" \
			--button="Edit Subnets":4 \
			--button="Don't scan any":3 \
			--button="Scan Selected":2 \
			<<< "$SCAN_SUBNETS"
			)
		if [ $? = "4" ]
			then
				edit-subnets				# edit the subnets file
				scan-subnets				# call this function again to scan any new subnets
			fi						# Falls though to selection below

		if [ -n "$OUT" ]					# if anything was selected
			then
			SCAN_SUBNETS=$(echo "$OUT" \
			| awk 'BEGIN{FS="|";OFS=""} {print $2;} '  \
			)						# Select the subnets to scan

			Stmp_out=$(mktemp --tmpdir `basename $0`.XXXXXXX)	# Somewhere to store output

			while IFS= read -r S_SN; do
			show-progress "Scanning" "Finding Servers on $S_SN" \
			"nmap -oG $Stmp_out --append-output -sn -PS2049 $S_SN" 	# find out what machines are available on the other subnets
			done <<<$SCAN_SUBNETS
	
			NFS_SUBNET_IPS=$(cat "$Stmp_out" \
			|grep "Status: Up" \
			|grep -o -E '([0-9]{1,3}\.){3}[0-9]{1,3}' \
			|sort -u
			)
			
			rm -f $Stmp_out			# delete temp file after reading content

			NFS_SUBNET_SERVERS=""

			for S_IP in $(echo "$NFS_SUBNET_IPS")
			do
				echo "# Scanning ... $S_IP"			# Tell zenity what we are doing 
		#		NFS_TMP=$(nc -zvw3 $S_IP $NC_PORT 2>&1)		# Using Showmount here is faster than NC
				NFS_TMP=$(showmount -e --no-headers $S_IP 2>&1)	# NC is the traditional way but showmount
									# gives the same exit code (ie $?=0 for sucess)
				if [ $? = "0" ]				# if nc connected sucessfully add this IP as an NFS server
				then
					NFS_SUBNET_SERVERS=$(echo -e "$NFS_SUBNET_SERVERS\n$S_IP")
				fi
			done> >(zenity --progress --pulsate  --width=250 --auto-close --no-cancel \
				--title="Scanning for NFS servers" \
				--text="Scanning .." \
				--percentage=0)					# Track progress on screen


			if [ -n "$NFS_SUBNET_SERVERS" ]; then

				NFS_SUBNET_IPS=$(echo "$NFS_SUBNET_SERVERS" \
				|awk -v sname="Remote Scanned" 'BEGIN{FS=" ";OFS=""} {print $1,",",sname,"\n" ;} ' \
				)

				NFS_SERVERS_FILE=""
				if [ -f $NFS_PNAME.servers ]; then # Get all from the existing .servers file
					NFS_SERVERS_FILE=$(cat $NFS_PNAME.servers)
 				fi
				NFS_NEW_SERVERS=$(echo -e "$NFS_SERVERS_FILE\n$NFS_SUBNET_IPS"|sort -u -t "," -k1,1) # remove any duplicates				
				echo "$NFS_NEW_SERVERS"|sed -e '/^$/d'|sort -u -t "," -k1,1 > $NFS_PNAME.servers	# Append IPS found to Servers for later processing, Ignore blank lines
			fi
		fi
	else
		zenity	--question --no-wrap \
			--title="No subnets found" \
			--text="No subnets found in $NFS_PNAME.subnets\n\nEdit the $NFS_PNAME.subnets file\nand try again?"
		if [ $? = "0" ]
		then
			edit-subnets				# edit the subnets file
		fi
		
	fi							# end scan subnets

	exec "./$NFS_PNAME"		# Restart the script with new possible server(s) in the .servers file
}
#------------- END scan-subnets--------------
#------------- edit-file --------------------
function edit-file() {
# Edit a support file
# Inputs $1=The file extension $2=A narrative/Instructions message
NFS_FILE="$NFS_PNAME.$1"

DOsave="N"				# Assume No Save

	if [ -n "$2" ]; then				# Display a Narrative/Instructions Dialog
		zenity --info --width=350 --timeout=$YADTIMEOUTDELAY \
		--title="Edit : $NFS_FILE" \
		--text="$2"
	fi

	if [ -f $NFS_FILE ]			# read the contents of the file if it exists
	then
		NFS_FILE_CONTENTS=$(cat $NFS_FILE)
	else
		NFS_FILE_CONTENTS=""
	fi

EDIT_TXT=$(zenity --text-info --width=350 --height=500 \
	--title="Edit : $NFS_FILE" \
	--editable \
	--checkbox="Save $NFS_FILE?" \
	 <<<$NFS_FILE_CONTENTS \
	)

	case $? in			# $? is the zenity return code
		0)DOsave="Y" ;;		# zenity/yad returns 0 for OK so save the  file
		1|70) ;;		# zenity/yad returns 1 for Cancel (Timeout or Close if --default-cancel is set)
		-1|252|255) ;;		# Just here to consider any other exit return codes (see zenity and yad documentation)
	esac
					# Exit with three variables set
					# DOsave = "Y" or "N"
					# EDIT_TXT = whatever was returned from the edit *"" if Cancelled*
					# NFS_FILE = Name of the file to save
}
# ------------ END edit-file ---------
#------------- edit-subnets --------------------
function edit-subnets() {

	NFS_NARRATIVE="<span foreground='blue'><b><big>Enter subnets in the format xxx.xxx.xxx.xxx/mm\nor xxx.xxx.xxx.xxx or xxx.xxx.xxx\n\n</big>ie 192.168.1.0/24\nor 172.162.2.0\nor 10.0.3</b></span>"
	edit-file subnets "$NFS_NARRATIVE"

if [ $DOsave = "Y" ]; then
	NFS_FILE_OUT=$(echo "$EDIT_TXT" \
	|grep -o -E '([0-9]{1,3}\.){2}[0-9]{1,3}' \
	|awk -v mask=".0/24" 'BEGIN{OFS=""} {print $1,mask ;} ' \
	|sort -u \
	)
	echo "$NFS_FILE_OUT"| sed -e '/^$/d' >$NFS_FILE	# Save any valid input to $NFS_FILE ignoring blanks
fi
}
# ------------ END edit-subnets ---------
#------------- edit-servers --------------------
function edit-servers() {

	NFS_NARRATIVE="<span foreground='blue'><b><big>Enter servers in the format xxx.xxx.xxx.xxx,name\n\n</big>ie 192.168.1.106,Nas1\nor 172.162.2.6	Server2</b>\n\nSeparate the two fields with <b>ONE</b> comma (,) or <b>ONE</b> TAB\n\nPut each server on a separate line</span>"
	edit-file servers "$NFS_NARRATIVE"

	if [ $DOsave = "Y" ]; then
		NFS_FILE_OUT=$(echo -n "$EDIT_TXT" \
		|grep -E '\b((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\.)){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5]))\b' \
		|awk 'BEGIN{FS="[,\t]";OFS=""} {print $1,",",$2,"\n" ;} ' \
		|sort -u -t "," -k1,1 \
		)				# grep extracts only Valid IP addresses and discards invalid

	echo "$NFS_FILE_OUT"| sed -e '/^$/d' >$NFS_FILE	# Save any valid input to $NFS_FILE ignoring blanks

#|grep -E '(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)' \

	fi
}
# ------------ END edit-servers ---------
#------------- find-nfs-servers ---------
function find-nfs-servers() {

# Find the available Servers on this subnet
	show-progress "Initializing" "Finding Servers on $NFS_SUBNET" \
	"arp-scan --localnet"	# find out what NFS servers are available on the current subnet
	
	NFS_LIVE_IPS=$(echo -e "$SP_RTN" \
		|grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		|grep -v "Interface" \
		|grep -v "DUP" \
		|awk 'BEGIN{FS="\t";OFS=""} {print $1,",",$3,"\n" ;} ' \
		|sort
		)	

		if [ -f $NFS_PNAME.servers ]; then	# Add the remote servers in .servers file
			NFS_LIVE_IPS1=$(echo "$NFS_LIVE_IPS")
			NFS_LIVE_IPS2=$(cat "$NFS_PNAME.servers")
			NFS_LIVE_IPS=$(echo "$NFS_LIVE_IPS2$NFS_LIVE_IPS1"|sort -u -t "," -k1,1) # remove any duplicates
 		fi
#--------------
							# Decide which of the live machines is an NFS server
#	NFS_TMP=""
#	NFS_SERVERS=""

#	for S_IP in $(echo "$NFS_LIVE_IPS" | awk 'BEGIN{FS=",";OFS=""} {print $1 ;} '  )
#	do
#		NFS_TMP=$(nc -zvw3 $S_IP $NC_PORT 2>&1)		# Using Showmount here is faster than NC
#		NFS_TMP=`showmount -e --no-headers $S_IP 2>&1`	# NC is the traditional way but showmount
							# gives the same exit code (ie $?=0 for sucess)
#		if [ $? = "0" ]				# if nc connected sucessfully add this IP as an NFS server
#		then
#			NFS_SERVERS=$(echo "$NFS_SERVERS$S_IP")
#		fi
#	done
# Ignore the above and just call showmount for everything *Faster than using Netcat (nc)
#----------------
#Find the available Shares/Volumes on the Servers found above
	AVAILABLE_VOLS=""							# Clear the variables
	NFS_SERVERS=""
	NFS_SERVERS_AND_NAMES=""
#	(							# Zenity progress this loop
	for S_IP in $(echo "$NFS_LIVE_IPS" | sed -e '/^$/d' | awk 'BEGIN{FS=",";OFS=""} {print $1 ;} '  )			# Find all available shares on all servers | sed -e '/^$/d' ignores blank lines
	do
		echo "# Scanning ... $S_IP"			# Tell zenity what we are doing 

		SP_RTN=$(ping -c 1 -W 2 $S_IP)			# See if the IP is alive

		if [ $? = 0 ]; then
			show-progress "Scanning for NFS Shares" "Finding Exports on $S_IP" \
			"showmount -e --no-headers $S_IP"
		else
			SP_RTN=""				# Show nothing found
		fi
		if [ -n "$SP_RTN" ]; then
			NFS_VOLS=$(echo "$SP_RTN" | grep -v "Export list for"| grep -v "RPC: Program not registered"| grep -v "RPC: Timed out"| grep -v "Unable to receive"|awk 'BEGIN{FS="*";OFS=""} {print "^:",$1 ;} '| sed -e 's/[[:space:]]*$//'  |sort)	# Select only rows without Export list for" ; print '^:' and the volume "| sed -e 's/[[:space:]]*$//'" removes trailing spaces
		else
			NFS_VOLS=""
		fi

		NFS_VOLS=$(sed 's/\^/'"$S_IP"'/g' <<<$NFS_VOLS)			# Replace the character "^" with the IP of the concerned server $S_IP and print the S_IP,VOLUME
		
		if [ -n "$NFS_VOLS" ]; then				# if we found anything shared
			AVAILABLE_VOLS=$(echo -e "$NFS_VOLS\n$AVAILABLE_VOLS")		# Append available servers shares to this servers shares 

			S_NAME=$(echo "$NFS_LIVE_IPS" |grep -w "$S_IP" |cut -d"," -s -f2)	#1. Find the machine name
			NFS_SERVERS=$(echo -e "$NFS_SERVERS\n$S_IP")				# 2. Recognize this IP as and NFS Server
			NFS_SERVERS_AND_NAMES=$(echo -e -n "$NFS_SERVERS_AND_NAMES\n$S_IP $S_NAME")	#3. Append the IP address and NETBIOS name to the list in $NFS_SERVERS_AND_NAMES
		fi
	done> >(zenity --progress --pulsate  --width=250 --auto-close --no-cancel \
	--title="Scanning for NFS servers" \
	--text="Scanning .." \
	--percentage=0)					# Track progress on screen

}
# --------------- END find-nfs-servers --------------
#---------------- select-share -------------
function select-share() {

	YAD_DLG_TEXT=$(echo "<span><big><b><big>Select the Server and Volume data</big>\nPress Escape to use the last mounted volume</b></big>\n\n" "$NFS_VOLUME" "\n$NFS_NETBIOSNAME" "</span>")

	set-netbiosname $NFS_VOLUME		# Get the NETBIOS name of the last used/selected server into NFS_NETBIOSNAME
	SELECT_VOLS=$(echo -e "TRUE\n$NFS_VOLUME\n$NFS_NETBIOSNAME")	# Put the last used server and share at the top of the list

	for S_VOLUME in $(echo "$AVAILABLE_VOLS" | grep -iwv "$NFS_VOLUME" | sort  )		# Find all available shares on all servers except the last used "| sed -e '/^$/d'" ignores blank lines
	do
		set-netbiosname $S_VOLUME			# Get the netbios name into NFS_NETBIOSNAME

		if [ -n "$S_VOLUME" ]						# if we found anything
		then
			CHECK_VOL=$(echo "$S_VOLUME" | awk -v sname="$NFS_NETBIOSNAME" 'BEGIN{FS="|";OFS=""} {print "FALSE\n",$1,"\n",sname ;} ') # make 2 columns (VOLUME NETBIOSNAME)
			SELECT_VOLS=$(echo -e "$SELECT_VOLS\n$CHECK_VOL")
		fi
	done
#

	OUT=$(yad --on-top  --center --window-icon $YAD_ICON --image $YAD_ICON --geometry=800x800\
		--center --on-top --close-on-unfocus --skip-taskbar --align=right --text-align=center --buttons-layout=spread --borders=25 \
		--separator="|" \
      		--title "Select Share" \
		--text="$YAD_DLG_TEXT" \
		--list --radiolist\
       		--columns=4 \
		--button="Exit":1 \
		--button="Edit Servers":4 \
		--button="Scan Subnets":3 \
		--button="Select":2 \
		--column "Sel" \
		--column "Volume" \
		--column "Server" \
	 	<<<"$SELECT_VOLS"
	)
	
	case $? in				# $? is the return code from the zenity/yad call
	0|2) ;;					# zenity/yad returns 0 for OK 2 is Select Button
	1|70) exit ;;				# Exit Button Selected

	3) scan-subnets	;;			# Scan the subnets and Restart the script with any 
						# new possible server(s) in the .servers file
						# *WILL RESTART THE WHOLE SCRIPT*

	4) edit-servers ;exec "./$NFS_PNAME";;	# Edit .servers file directly *Will restart the script*

	-1|252|255) ;;				# Just here to consider any other exit return codes (see zenity and yad documentation)
	esac

	SP_RTN=$(echo "$OUT" \
	| cut -d "|" -s -f2,3 \
	)
	
	}

#---------------- end select-share -------------
export -f select-mounted select-share find-nfs-servers scan-subnets edit-file edit-subnets edit-servers

# --------------------------------------------------------------------End functions------------------------------------------------------------------------

# -- Proceed with Main()

# -- Check Dependancies -----

# We need to have
# 1. arp-scan to allow the searching for, active machines (Potentially NFS servers)
# 2. mount.nfs to mount NFS volumes
# 3. nc to interact with NFS
# 4. nmap to scan subnets
# 5. yad to give functional and usable dialog inputs

NOTINSTALLED_MSG=""						# Start with a blank message

#1.. Look for arp-scan
which arp-scan >>/dev/null 2>&1					# see if arp-scan is installed
if [ $? != "0" ]; then
       	NOTINSTALLED_MSG=$NOTINSTALLED_MSG"arp-scan\n"		# indicate not installed		
fi

#2.. Look for mount.nfs
which mount.nfs >>/dev/null 2>&1				# see if mount.nfs is installed
if [ $? != "0" ]; then
       	NOTINSTALLED_MSG=$NOTINSTALLED_MSG"mount.nfs\n"		# indicate not installed		
fi

#3.. Look for nc
which nc >>/dev/null 2>&1					# see if nc is installed
if [ $? != "0" ]; then
       	NOTINSTALLED_MSG=$NOTINSTALLED_MSG"nc\n"		# indicate not installed		
fi

#4.. Look for nmap
which nmap >>/dev/null 2>&1					# see if nmap is installed
if [ $? != "0" ]; then
       	NOTINSTALLED_MSG=$NOTINSTALLED_MSG"nmap\n"		# indicate not installed		
fi

#5.. Look for yad
which yad >>/dev/null 2>&1					# see if yad is installed
if [ $? != "0" ]; then
	YADNOTINSTALLED_MSG="yad not found!\nInstall yad package\n Using\n\n 'sudo dnf install yad' (Fedora/RedHat)\n\n'sudo apt install yad' UBUNTU/Debian"

	zenity	--warning --no-wrap \
	--title="YAD Missing" \
	--text="$YADNOTINSTALLED_MSG" \

fi

if [ -n "$NOTINSTALLED_MSG" ]; then
	NOTINSTALLED_MSG=$NOTINSTALLED_MSG"not found!\n\nInstall arp-scan,mount.nfs,nmap and nc\n Using\n\n 'sudo dnf install arp-scan nfs-common nmap netcat' (Fedora/RedHat)\n\n'sudo apt install arp-scan nfs-common nmap netcat' UBUNTU/Debian"
 
	zenity	--error --no-wrap \
	--title="Missing Dependancies" \
	--text="$NOTINSTALLED_MSG" \

	exit							# exit and fail to run	
fi
# -- END Check Dependancies -----

#----- Read $1 and set the User and Group ID for the mount command
# Since we have to run this scipt using sudo we need the actual user UID. This is set by the execution script that called us
# The UID is passed as $arg1 i.e "./mntNFS $NFS_ID" (see the mntNFS script) comes as 'uid=nnnn gid=nnnn'
# We need to use awk to add the commas into it to use as input to mount

NFS_PNAME=$2						# Get the actual name of the calling user/script
#
if [ -f $NFS_PNAME.ini ]; then
	. $NFS_PNAME.ini				# include the variables from the .ini file (Will orerwrite the above if $2.ini found)
fi

if [ -f $NFS_PNAME.last ]; then						
	. $NFS_PNAME.last				# load last sucessful mounted options if they exist (Overwrites .ini)
fi

if [ ! -z $NFS_PNAME ] ; then
	MOUNT_POINT_ROOT=$NFS_MOUNT_POINT"/$NFS_PNAME"	# Append the user calling user name if set as $2
	if [ ! -d $MOUNT_POINT_ROOT ]; then
		mkdir $MOUNT_POINT_ROOT				# make the mountpoint directory if required.
	fi
fi

which yad >>/dev/null 2>&1					# see if yad is installed
if [ $? = "0" ]; then
	USEYAD=true 						# Use yad if we can (Maybe suggest to install later ..note to self.. TBD)
	export GDK_BACKEND=x11					# needed to make yad work correctly

	if [ -f $NFS_PNAME.png ]; then
		YAD_ICON=$NFS_PNAME.png 			# Use our Icon if we can ($0.png is an icon of a timecapsule
	       							# (Not required but just nice if we can)
	else

#		YAD_ICON=gnome-fs-smb				# Default Icon in the YadDialogs from system
#		YAD_ICON=gnome-fs-ftp				# Default Icon in the YadDialogs from system
		YAD_ICON=gnome-fs-nfs				# Default Icon in the YadDialogs from system
#		YAD_ICON=drive-harddisk				# Default Icon in the YadDialogs from system
#		YAD_ICON=network-server				# Default Icon in the YadDialogs from system
	fi
	export YAD_ICON
else 
	USEYAD=false						# yad is not installed, fall back to zenity
fi
# look for subnets file
# if it doesnt't exist make one and add our subnet to it. ie. 192.168.1.0/24

NFS_SUBNET=$(ip route | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}'/ |cut -d" " -s -f1 |grep -v 169.254 )

if [ -f $NFS_PNAME.subnets ]; then
	NFS_CURRENT_SUBNETS=$(cat $NFS_PNAME.subnets |grep -v $NFS_SUBNET ) # remove any current entry for this subnet
fi

# Start Processing

find-nfs-servers

export NFS_SERVERS_AND_NAMES NFS_SERVERS AVAILABLE_VOLS					# Make availabe for the functions

#	First of all .. Present a total list of any mounted volumes and give options to umount if required
	M_PROCEED='no'
	while [ "$M_PROCEED" ]
	do
		select-mounted								# Present a list of currently mounted volumes
	done								# repeatedly until nothing is mounted or Proceed button selected
#	Then .. Present a total list of any shares available on the subnet for preliminary selection
	select-share									# Select a server and share from the selection list (Returns IP|NETBIOSNAME|SHARE)

		if [ -n "$SP_RTN" ]; then
			IFS="|" read  NFS_VOLUME NFS_NETBIOSNAME tTail<<< "$SP_RTN"  # tTail picks up any spare seperators
			NFS_IP=$(echo $NFS_VOLUME | cut -d":" -s -f1)	# get the IP address from the volume string
		fi
#
# Get user input to confirm default or selected values
InputPending=true									# Haven't got valid user input yet
while $InputPending
do
		if $USEYAD ; then	# Use yad if we can
# Format the server list for YAD dropdown list
		CHECK_SRV=""							# Start with a blank list
		if [ -n "$NFS_SERVERS_AND_NAMES" ]; then			# if we found any servers
			CHECK_SRV=$(echo "$NFS_SERVERS_AND_NAMES" \
			| grep -iwv $NFS_IP \
			| sed -e '/^$/d' \
			| awk 'BEGIN{FS=" "} {OFS=" "} {print $1," - "}{$1 = ""; print $0;} ' \
			) 		# select only and ALL lines except the last mounted Server IP
		fi
					# grep -iv ignores the last sucessful mounted server
					# the last mounted server. is added at the top of the list later
					# sed -e '/^$/d' \ removes any blank lines
					# Paste into one row delimted by '!' 
		if [ -n "$CHECK_SRV" ]; then
			CHECK_SRV="!$CHECK_SRV"						# if something found add a delimeter before it 
		fi

		set-netbiosname $NFS_VOLUME			# Get the NETBIOS name of the last used/selected server into NFS_NETBIOSNAME
								# if it is offline dont include the pango markup set by set-netbiosname
		if ! $NFS_LASTSERVERONLINE ; then
		NFS_NETBIOSNAME="**OFFLINE**"  						# Server is offline
	fi

# finally make the drop down list (Remember to consider that we changed the ' ' for '-' when we parse the result below	
		SEL_AVAILABLE_SERVERS=$(echo $NFS_IP" - "$NFS_NETBIOSNAME$CHECK_SRV'!other' )
											# Add the last used server at the top, append "other" to allow input of a server not found above
											# Replace the one space seperator (' ') with ' - ' (Make it pretty) like the awk paste OFS above
#Format the Volumes list											
		CHECK_VOLS=$(echo -e "$AVAILABLE_VOLS" \
		| sed -e '/^$/d' \
		| grep -iv "$NFS_VOLUME" \
		| tr '\n' '!'
		) 	# select only and ALL lines from the available shared volumes
			# | sed -e '/^$/d' \ ignores any blank lines
			# grep -iv ignores the last sucessful mounted volume to avoid duplicates in the list
			# the last mounted vol. is added at the top of the list later
			# Paste into one row delimited by '!'

		CHECK_VOLS="!$CHECK_VOLS"		# if something found add a delimeter before it 
		SEL_AVAILABLE_VOLS="$NFS_VOLUME$CHECK_VOLS other"			# Add the last used volume at the top and append "other" to allow input of a share not found above

# Get the input
		Voldetail=$(yad --form --width=700 --separator="," --center --on-top --skip-taskbar --align=right --text-align=center --buttons-layout=spread --borders=25 \
		       		--window-icon $YAD_ICON --image $YAD_ICON \
				--title="Server/Share details" \
				--text="\n<span><b><big><big>Enter the Server and Volume data</big>\n</big></b></span>\n" \
				--field="IP Address of NFS Server ":CBE "$SEL_AVAILABLE_SERVERS" \
				--field="Volume/Share to mount ":CBE "$SEL_AVAILABLE_VOLS" \
				--field="\n<b>Select 'Ignore' to ignore any changes here and proceed to mount with default values\n \
				\nOtherwise select 'Mount' to accept any changes made here</b>\n":LBL \
				--field="":LBL \
				--button="Save as Default":2 --button="Ignore - Use Defaults":1 --button="Mount - This Volume":0 \
			 )
		else  									# else revert to zenity

		Voldetail=$(zenity --forms --width=500 --title="NFS Server details" --separator=","  \
				--text="\nSelect Cancel or Timeout in $YADTIMEOUTDELAY Seconds will ignore any changes here and proceed to mount with default values\n" \
				--add-entry="IP Address of NFS Server - "$NFS_IP \
				--add-entry="Volume/Share to mount - "$NFS_VOLUME \
				--default-cancel \
				--ok-label="Mount - This Volume" \
				--cancel-label="Ignore - Use Defaults" \
				--timeout=$YADTIMEOUTDELAY \
			)
		fi									# end "If yad is istalled"	
# Check exit code and collect new variables from Vol detail if given
		case $? in
			0) ;;						# OK so collect input else leave all vars asis
			70) InputPending=false ; exit ;;		# 70=Timed out no change to $default set variables *drop out of the while loop
			1|251)InputPending=false ; break ;;		# 1 251 User pressed Cancel use default set of variables
			2) FORCESAVEINI=true ;;				# User Selected "Save Defaults" Flag to force save defaults
			-1|252|*)  exit -1 ;;				# Some error occurred (Catchall)
		esac
# got input.. validate it

	IFS="," read  tNFS_IP tNFS_VOLUME tTail<<< "$Voldetail" # tTail picks up any spare seperators

	tNFS_IP="$tNFS_IP "					# Add a trailing space for the 'cut' commmand below
	tNFS_IP=$(echo "$tNFS_IP" \
		|cut -d" " -s -f1 \
		|tr -d '[:space:]')					# Get the IP address ONLY from the input
	
	ENTRYerr=""					# Collect the blank field names 
	if [ -z "$tNFS_IP" ]; then ENTRYerr="$ENTRYerr IP,"
	fi
	if [ -z "$tNFS_VOLUME" ]; then ENTRYerr="$ENTRYerr Volume,"
	fi

	if [ -z "$ENTRYerr" ]; then				# no fields are blank

		if [[ "$NFS_IP" != "$tNFS_IP" ]] || \
		[[ "$NFS_VOLUME" != "$tNFS_VOLUME" ]] || \
	       	[[ $FORCESAVEINI ]]\
		; then									# If anything changed or user selected save defaults button

			if $USEYAD ; then		# Use yad if we can (Maybe suggest to install later ..note to self.. TBD)
				SP_RTN=$(yad --form  --separator="," --center --on-top --skip-taskbar --align=right --text-align=center --buttons-layout=spread --borders=25 \
					--image=document-save \
					--title="Save $NFS_PNAME.ini" \
					--text="\n<span><b><big><big>Your Server/Share data Input</big></big></b></span>\n" \
					--field="IP Address of NFS Server ":RO "$tNFS_IP" \
					--field="Volume/Share to mount ":RO "$tNFS_VOLUME" \
					--field="\n\n<span><b><big>Do you want to save these values as defaults?</big></b></span>\n":LBL \
					--field="":LBL \
					--button="Dont save":1 --button="Save as Default":0 \
					--timeout=$YADTIMEOUTDELAY --timeout-indicator=left
				)
			else
				SP_RTN=$(zenity --question --no-wrap \
					--title="Save $NFS_PNAME.ini" \
					--text="\n Your Server/Share data Input \n \
						IP Address of NFS Server - "$tNFS_IP"    \n \
						Volume/Share to mount - "$tNFS_VOLUME"    \n \
						\nDo you want to save these values as defaults?    " \
					--default-cancel \
					--ok-label="Save as Default" \
					--cancel-label="Dont save" \
					--timeout=$TIMEOUTDELAY
					)
			fi					# endif USEYAD

			case $? in					# $? is the return code from the zenity/yad call
				0)DOsave_vars="Y" ;;			# zenity/yad returns 0 for OK so save the .ini file
				1|70) ;;				# zenity/yad returns 1 for Cancel (Timeout or Close if --default-cancel is set)
				-1|252|255) ;;				# Just here to consider any other exit return codes (see zenity and yad documentation)
			esac

		fi						# end check for any changes

		IFS="," read  NFS_IP NFS_VOLUME tTail<<< "$Voldetail"  # tTail picks up any spare seperators

		NFS_IP="$NFS_IP "					# Add a trailing space for the 'cut' commmand below
		NFS_IP=$(echo "$NFS_IP" \
		|cut -d" " -s -f1 \
		|tr -d '[:space:]')					# Get the IP address only from the input (remember we exchanged the ' ' for '-' when we formatted the list
	
		InputPending=false					# got the input that we wanted, None of the fields are blank, moved them into the variables and continue

		if [[ "$DOsave_vars" = "Y" ]]; then			# save the input as default for next time
			save-vars "ini"
		fi
	else								# One or more of the vars is blank
		zenity	--error --no-wrap \
			--title="Server data input error" \
			--text="Input error!!...  \n\n $ENTRYerr cannot be blank \n\nTry again  " \
			--timeout=$TIMEOUTDELAY
	fi								# Check input for errors

done

MOUNTDIR=$(echo $NFS_VOLUME|awk 'BEGIN{FS="/"} {print $NF ;} ')	# Get the last field from the vol name
MOUNT_POINT="$MOUNT_POINT_ROOT/$MOUNTDIR"			# Where we are going to mount... no need to create the directory we, will do it as we go

#Start Processing mount
#Check if it (Or something else) is already mounted at $MOUNT_POINT
IS_MOUNTED=`mount 2> /dev/null | grep -w "$MOUNT_POINT" | cut -d' ' -f3`

if [[ "$IS_MOUNTED" ]] ; then

		zenity 	--question --no-wrap \
			--title="Volume Already in use" \
			--text="$NFS_VOLUME or something else is currently mounted at $MOUNT_POINT   \n\nDo you want to unmount and stop using it?" \
			--default-cancel \
			--ok-label="Unmount" \
			--cancel-label="Continue Using" \
			--timeout=$TIMEOUTDELAY

		case $? in					# $? is the return code from the zenity call
    			0)ProceedToUnmount="Y"	;;		# zenity returns 0 for OK 
    			1|70)ProceedToUnmount="N"	;;	# zenity returns 1 for Cancel (Timeout or Close if --default-cancel is set)
			-1|252|255)ProceedToUnmount="N" ;;	# Just here to consider any other exit return codes (see zenity documentation)
		esac

		# $? (zenity exit code) parsed into ProceedToUnmount above in the case statement.
		# Switched 0 (OK) to "Y" and 1 (Cancel) to "N" (Just for code clarity.) 
	
	if [[ $ProceedToUnmount =~ [Yy] ]] ; then

# ---------- umount and trap any error message

		unmount "$MOUNT_POINT"							# Attempt to unmount volume

		if ! $UNMOUNT_ERR  ; then
			if [ -f "$0.last" ]; then
				rm -f "$0.last"						# Unmounted so delete last mounted vars temp file (restart next time with .ini file)
			fi
		else									# unmount failed
			exit 1
		fi 									# if umount $MOUNT_POINT
		else									# decision given to keep what is currently mounted ($ProceedToUnmount == Y)

		zenity	--info --no-wrap \
			--title="Retain mounted Volume" \
			--text="Continue to use previously mounted $MOUNT_POINT  " \
			--timeout=$TIMEOUTDELAY
	fi 										#$ProceedToUnmount decision
	
	exit 0		#Sucess

else		# Not yet mounted so Proceed to attempt mounting

		if [ "$MOUNT_POINT" != "$MOUNT_POINT_ROOT" ]; then			# Dont try to create the mount root if mount point is not set correcly

			if [ ! -d "$MOUNT_POINT" ]; then
				mkdir "$MOUNT_POINT"		# make the mountpoint directory if required.
			fi
		fi
# ---------- mount and trap any error message
		MNT_CMD="mount -t nfs '$NFS_VOLUME' '$MOUNT_POINT' -w -o rw,x-gvfs-show"

		show-progress "Mounting" "Attempting to mount $NFS_VOLUME" "$MNT_CMD"

		ERR=$(echo "$SP_RTN" | grep -v "Created symlink")	# Read any error message
									# The "Created symlink" message comes up the first time
									# That we run but the mount suceeds, So ignore it

# --- end mount (any error message is in $ERR

		if [ -z "$ERR" ] ; then
			zenity	--info --no-wrap \
				--title="Volume is Mounted" \
				--text="Volume $NFS_VOLUME is Mounted  \n\nProceed to use it at $MOUNT_POINT  \n\n.... Success!!" \
				--timeout=$TIMEOUTDELAY 

		save-vars "last" 							# save the as the last Volume used

		else									# if mount fails #Clean UP

			if [ "$MOUNT_POINT" != "$MOUNT_POINT_ROOT" ]; then		# Dont remove the mount root is mount point is not set correcly
				rmdir "$MOUNT_POINT"					# Happened during testing DUHHH
			fi

			zenity	--error --no-wrap \
				--title="Volume is NOT Mounted" \
				--text="Something went wrong!!...  \n\n $ERR \n\n Failed to mount NFS Volume $NFS_VOLUME at $MOUNT_POINT \ntry again  " \

			exit 1
		fi		# end if mount -t nfs $NFS_VOLUME

fi		# IS_MOUNTED
exit 0
