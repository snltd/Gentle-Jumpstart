#!/bin/ksh

# Logging is complicated.
# This script may be run on the Jumpstart server, locally on any old
# machine, or, as is normal, locally on a Jumpstart client.
# IN A JUMPSTART:
# i)   the Jumpstart client's log file - /var/sadm/system/logs/jumpstart.log
# ii)  the Jumpstart client writes a log file back on the server
#      /var/log/blase/clients/client.jumpstart-log SERVER
#      /log/clients/$client/client.jumpstart-log CLIENT
# iii) the script itself writes a log file.
#      /var/log/blase/master.log, SERVER
#      /log/master.log CLIENT
# IN A LOCAL RUN
# i)   The local run log file /var/log/blase/local_client_log
# ii)  The script itself logs to /var/log/blase/master.log
#-------------------------------------------------------------------------------
# VARIABLES

# set the PATH is set for convenience and security

PATH=/bin:/sbin:/usr/sbin

# A bit of type setting

typeset -i i

set -A SCR_ARR
	# SCR_ARR is an array we use to build a list of finish scripts to work
	# with.  We use an array rather than a temp file partly for security
	# reasons (this script runs as root, we don't want people guessing the
	# temp name) and partly for neatness. I hate accessing the filesystem
	# unless I have to.

MY_VER="0.1"
SUN_VER=$(uname -r)
SOL_VER=${SUN_VER#5.}


# Many variables are different depending on whether or not we're
# Jumpstarting

if [[ -n $SI_CONFIG_DIR ]]
then
	SCR_BASE=$SI_CONFIG_DIR
	CONFIG="${SCR_BASE}/config/config_js.sh"
else
	cd ${0%/*}/..
	SCR_BASE=$(pwd)
	cd -
	CONFIG="${SCR_BASE}/config/config_local.sh"
fi
echo $SCR_BASE

. $CONFIG || { print "can't find library file"; exit 1; }
. $LIBRARY || { print "can't find library file"; exit 1; }

i=0 # i is an integer counter

#-------------------------------------------------------------------------------
# FUNCTIONS

function display_help
{
	cat <<-EOHELP

	  usage: ${0##*/} [-D] [-hvV] [-R <directory>] [-L] [-d<directory>]
	  [-f<file> | script1 ... script n]"

	    -D : enable debugging - must be supplied as the first option
	    -a : run all available finish scripts
	    -d : use finish scripts in given directory
	    -f : take the finish script list from a file rather than from the
	         command line
	    -l : list available finish scripts
	    -h : display this message
	    -L : perform a local install - requires -R to be set also
	    -R : root of filesystem to work on
	    -v : display version information
	    -V : display more version information
  
	  Finish scripts can be run with arguments by enclosing the script name
	  and the arguments in quotes, for example:

	    master.sh -D "F01example arg1 arg2" F02example "F03example arg3"

	EOHELP
}

function list_scripts
{
	# print a list of all the finish scripts we know about, along with their
	# descriptions, all nicely formatted

	debug "listing scripts in $F_DIR"

	# Make the column of script names 20 characters wide. Purely aesthetic I
	# assure you

	typeset -L20 pfscript 

	# Just look at each script, pulling out the SCR_DESC and printing it
	# alongside the script name. Not hugely elegant, but good enough for
	# what we're doing

	ls $F_DIR/F* | while read fscript
	do
		pfscript=${fscript##*/}
		unset SCR_DESC
		eval $(grep ^SCR_DESC $fscript)
		print "  ${pfscript} ${SCR_DESC:-** no description provided **}"
	done

}

function run_finish_script
{
	# Execute a finish script. Probably the most important function in the
	# script.
	# $1 is the script name
	# $2 is the arguments - QUOTE THEM!

	# Does the script exist and is it executable?

	[[ -f ${F_DIR}/$1 ]] || \
	{ warn  "script does not exist [ $1 ]"; return 1; }

	[[ -x ${F_DIR}/$1 ]] || \
	{ warn  "script is not executable [ $1 ]"; return 1; }

	# Run the script, and log correctly. Anything the finish scripts write
	# to standard error should go in the main log file

	print -n "\nRUNNING $1" | tee -a $CLIENT_LOG_FILE $SERVER_LOG_FILE

	[[ -n "$2" ]] && print " with args $2" \
	| tee -a $CLIENT_LOG_FILE $SERVER_LOG_FILE || print

	$F_DIR/$1 $2
	RET_CODE=$?

	#{ RET_CODE=$({ { $F_DIR/$1 $2 2>$SERVER_LOG_FILE  4>&- 
	#print $? >&4 4>&- 
	#} | tee -a $CLIENT_LOG_FILE $SERVER_LOG_FILE 4>&- 
	#} 4>&1 >&3 3>&-)
	#} 3>&1

	if [[ $RET_CODE -eq 0 ]]
	then
		print "  $1 completed successfully"
	else
		print "failed"
		print "  $1 returned $RET_CODE [ see $SERVER_LOG_FILE ]"
		
		# Any finish script can abort the entire customization process at
		# any time by exiting 100. Look for that

		[[ $RET_CODE -eq 10 ]] && die "exiting on order of $1"
	fi | tee -a $CLIENT_LOG_FILE $SERVER_LOG_FILE

}

function mount_log_dir
{
	# The main Jumpstart directories must be shared read-only, but we want
	# our client to log to the Jumpstart server, so we have centralised logs
	# of all builds. So, we have to mount a special log directory read/write
	# $1 is where to mount

	mkdir -p $1
	RET=1 # Assume failure

	# make sure we can see the log directory - it should show up in a
	# showmount XXX can check modes?
	
	if showmount -e $SERVER_IP | egrep -s ^$LOG_SHARE
	then
		debug "Log directory is exported by server" \
		# now try and mount it
		log "mounting log directory ${SERVER_IP}:$LOG_SHARE on $1"
		debug "mounting log directory ${SERVER_IP}:$LOG_SHARE on $1"

		if mount -orw ${SERVER_IP}:$LOG_SHARE $1 
		then
			debug "log directory mounted successfully" 
			mkdir -p $SERVER_LOG_DIR

			# now check we can write to it

			if touch $SERVER_LOG_FILE 2>/dev/null 
			then
				debug "log file is writable"
				RET=0
			else
				debug "ERROR: log file is not writable [ $SERVER_LOG_FILE ]"
			fi

		else
			debug "ERROR: could not mount log dir ${SERVER_IP}:$LOG_SHARE on $1"
		fi

	else
		debug "ERROR: log directory [ $LOG_SHARE ] is not exported"
	fi

	log "mounted log directory"

	return $RET
}

#-------------------------------------------------------------------------------
# SCRIPT STARTS HERE

# Get our options. The order of the case orders precedence.

while getopts "aDd:f:hLlR:vV" option 2>/dev/null
do
    case $option in

		h)	display_help
			exit 0
			;;

		v)	# print version info
			my_version
			exit 0
			;;

		V)	# print extended version info
			generic_info
			exit 0
			;;
			
		D)	# Enable debugging
			DEBUG=true
			debug "debugging enabled"
			;;

		d)	# override default finish script directory
			
			F_DIR=$OPTARG

			# make a relative path absolute

			print $F_DIR | egrep ^/ || F_DIR="$(pwd)/$F_DIR"

			[[ -d $F_DIR ]] \
			|| die "finish script directory does not exist [ $F_DIR ]"

			[[ $(ls $F_DIR/F* | wc -l) -gt 0 ]] || die \
			"no finish scripts in ${F_DIR}. Filenames must begin with 'F'"

			debug "taking $F_DIR as finish script directory"
			;;

		a)	# run all scripts
			RUN_ALL=1
			debug "running all scripts in $F_DIR"
			;;

		f)	# get the script list from a file
			SCR_FILE=$OPTARG

			[[ -f $SCR_FILE ]] || die "can't find script file [ $SCR_FILE ]"

			debug "taking scripts from $SCR_FILE"
			;;

		R)	# Set the root for running finish scripts, and make sure it
			# looks okay

			ROOT=$OPTARG

			[[ -d $ROOT ]] || die "Invalid root directory [ $ROOT ]"

			debug "using $ROOT as root directory"
			;;

		l)	# list available finish scripts
			list_scripts
			exit 0
			;;

		L)	# are we doing a local install?
			LOCAL=1
			;;

		*)	print "unkown option(s). Use -h for help"

			
	esac

done

shift $(($OPTIND - 1))

# check for finish scripts

[[ -d $F_DIR ]] || die "no finish script directory [ $F_DIR ]"

# get the list of scripts to run. If scripts are called multiple times, then
# they will be run once if there are no arguments, or multiple times if
# there are multiple calls with differing arguments

if [[ -n $SCR_FILE ]]
then
	# we're using a file. We don't need to do anything with it, the
	# processing is at the end of the code block so we can deal with files
	# and arg lists in the same way.  Catting a single file? Call yourselves
	# bloody professionals? Print to stderr so it doesn't end up in the pipe

	print -u2 -n "Taking finish script list from $SCR_FILE"
	[[ $# -gt 0 ]] && print -u2 ". (Ignoring arguments.)" || print -u2 "."

	cat $SCR_FILE
elif [[ -n $RUN_ALL ]]
then
	# We're running every finish script we have, with no arguments

	ls $F_DIR/F* | sed -e 's/^.*\///'
else
	# we're using command line arguments. Remember that args can be appended
	# by surrounding the script and its args in quotes, so just use the
	# simple form of for

	for fscr 
	do
		print -- $fscr
	done

fi | egrep ^F | sort -u | while read fscr
do
	SCR_ARR[$i]=$fscr
	i=$(($i + 1))
done

if [[ -n $DEBUG ]]
then
	i=0
	debug "finish script list:"

	while [[ -n ${SCR_ARR[$i]} ]]
	do
		debug "${SCR_ARR[$i]}"
		i=$(($i + 1))
	done

fi

# We now have an array holding all our finish scripts and the arguments they
# take, in numerical order.

# Because we don't (currently) have an interface to tell us what network
# we're installing for, we'll have to take a guess. Saw the last number off
# and tag on a dot-zero. I tried using the documented SI_HOSTADDRESS
# variable here, but it wasn't being set

ADDR=$(ifconfig -a | sed -n '/broadcast/s/^.*inet \([^ ]*\) .*$/\1/p')

NETWORK="${ADDR%.*}.0"

print "network is $NETWORK [ from $ADDR ]"

#- EXECUTE SCRIPTS -----------------------------------------------------------
# The finish scripts expect certain variables to be set and exported. Some
# variables will be defined by Jumpstart, so if we're working locally, we
# need to define them ourselves

# ROOT is the mountpoint of the FS we're operating on
# F_DIR is the directory where the finish scripts live
# CLIENT is the name of the Jumpstart client
# CONF_DIR is the client specific Jumpstart config directory, under JSFS
# SERVER_IP is the address of the Jumpstart server, needed so the client can
# mount the log directory
# CLIENT_LOG_FILE is the log written locally in a JS
# SERVER_LOG_FILE is the log written back to the server in a JS

if [[ -n $LOCAL ]]
then
	# we're working locally. Is ROOT set?

	[[ -n $ROOT ]] || die "please set a root directory with -R"

	debug "preparing for local application of finish scripts on $ROOT fs"
	CONF_DIR=$(get_conf_val directories f_conf_dir)
	CLIENT_LOG_FILE=$(get_conf_val paths local_client_log)
else
	# we're doing a Jumpstart. Or are we?

	[[ -n $SI_CONFIG_DIR ]] || die "this is not a Jumpstart install"

	ROOT=/a
	debug "preparing for Jumpstart application of finish scripts"

	# Only try to mount the log directory if we can see the server

	if ping $SERVER_IP 1
	then
		mount_log_dir $SERVER_LOG_MNT || SERVER_LOG_FILE="/dev/null"
	else
		debug \
		"cannot see server at ${SERVER_IP}. Finish script logging disabled"
		SERVER_LOG_FILE="/dev/null"
	fi

fi

mkdir -p $CLIENT_LOG_DIR
touch $CLIENT_LOG_FILE

# Set IN_CONTROL and we can run the finish scripts

IN_CONTROL=1
	# the finish scripts look to see if IN_CONTROL is set. If not, they
	# won't run

BASE=${SI_CONFIG_DIR}

export CLIENT CONF_DIR ROOT CONF_DIR IN_CONTROL JSFS NETWORK SOL_VER \
SUN_VER BASE

# Nearly ready! enable logging if we can. If we don't have a readable
# directory then logging will keep going to /dev/null. You'll still get the
# console output of course, including the debug notices if you requested
# them.

# Run some last minute directory checks and we're ready to go

[[ -d $CONF_DIR ]] && debug "found client config direcotry [ $CONF_DIR ]" \
|| die "no client config directory [ $CONF_DIR ]"

[[ -w $CLIENT_LOG_FILE ]] && debug "client log ok [ $CLIENT_LOG_FILE ]" \
|| die "cannot write to client log [ $CLIENT_LOG_FILE ]"

[[ -w $SERVER_LOG_FILE ]] && debug "server log ok [ $SERVER_LOG_FILE ]" \
|| die "cannot write to server log [ $SERVER_LOG_FILE ]"

[[ -d $F_DIR ]] || die "no finish script directory [ $F_DIR ]"

# Simply step through the script array, executing one at a time.
# run_finish_script() does the meat of the work.

i=0
	# to step through SCR_ARR. Why isn't ksh93 standard by now?

FSCR_ERR=0
	# FSCR_ERR counts how many finish scripts exit non-zero. This script
	# exits with the value of FSCR_ERR

while [[ -n ${SCR_ARR[$i]} ]]
do
	print ${SCR_ARR[$i]} | read scr_to_run args_to_run
	run_finish_script $scr_to_run "$args_to_run" \
	|| FSCR_ERR=$(($FSCR_ERR + 1))
	i=$(($i + 1))
done

exit $FSCR_ERR
