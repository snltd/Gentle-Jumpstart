#!/bin/ksh

#=============================================================================
#
# setup_client.sh
# ---------------
#
# A wrapper to add_install_client. 
#
# v1.0 Finally tidied up and commented. Prettier output, more robust, and
#      about half the size it was. RDF
#
# v1.1 Added support for multi-homed jumpstart servers. NWP
#
# v2.0 Code tidy-up, nicer output, added options to force creation of new
#      sysidcfg (-s)  and profile (-p) files, and to specify client
#      architecture (-a). The -f option lets the user specify which finish
#      scripts to run in a comma separated list, or via the special "all"
#      and "none" keywords. Support for Solaris 2.6 and 7. Support for
#      Jumpstart mirroring through the -m option, and specification of the
#      root disk in a non-mirrored configuration via -R. RDF 23/08/09
#
# v2.1 Basic installation by flash archive is now supported via -F option.
#      Path to archive is supplied in ip_addr:/path/file.flar form.
#      Currently only install_types of flash_install are supported (so no
#      flash upgrades). Finally made -u work. RDF 06/10/09
#
# v2.2 Rudimentary ZFS support. Update rules.ok file on OpenSolaris because
#      check no longer works. RDF 17/10/11
#
# v2.3 Add packages though ADD_PKG variables. Different install clusters
#      with -c. Better ZFS support. 
#
# R Fisher 
#
#=============================================================================

#-----------------------------------------------------------------------------
# VARIABLES

JS_DIR="/js/export"
	# Base of our Jumpstart installation

JS_CLIENT_BASE="${JS_DIR}/clients"
	# Where client configuration directories go

JS_IMG_BASE="${JS_DIR}/images"
	# Where Solaris images go

ROOT_PASSWD='G929XW4UpVyxI'
	# Encrypted root password that clients will be given.

ROOTDEV="c0t0d0"
	# Boot disk device. Can be overriden with -R option

RPOOL="rpool"
	# root pool if using ZFS

RPOOLSIZE="auto"
	# size of root pool - override with -S

SWAPSIZE="auto"
	# size of swap on ZFS root - override with -T

BE="initial"
	# initial boot environment name if using ZFS

CLUSTER="SUNWCreq"
	# Default Solaris install cluster. Override with -c

typeset -R20 TO_PRINT
	# For formatting output

TMPFILE="/tmp/js_rules.$$"

ADD_PKG_Solaris_8="SUNWntpr SUNWntpu"
	# Packages to add to 5.8 installs

ADD_PKG_Solaris_9="SUNWntpr SUNWntpu SUNWzlib SUNWgss SUNWfns SUNWgssc
	SUNWlibC SUNWsshcu SUNWsshdr SUNWsshdu SUNWsshr SUNWsshu SUNWuiu8
	SUNWuiu8x SUNWggrp SUNWgtar SUNWgcmn"
	# Packages to add to 5.9 installs

ADD_PKG_Solaris_10="SUNWsshcu SUNWsshdr SUNWsshdu SUNWsshr SUNWsshu SUNWuiu8
	SUNWluzone SUNWzoner SUNWzoneu SUNWpoolr SUNWpool SUNWntpr SUNWntpu
	SUNWggrp SUNWgtar SUNWgcmn SUNWfss"
	# Packages to add to 5.10 installs

#-----------------------------------------------------------------------------
# FUNCTIONS

function die
{
	# Error handling

	print -u2 "ERROR: $1"
	exit ${2:-1}
}

function usage
{
	cat <<-EOUSAGE
	  ${0##*/} [-m cxtxdx:cytydy] [-f list] [-R cxtxdx] [-a arch]  [-S size]
	          [-c cluster] [-psu] [-F archive] <directory> <client>

	where:
	    -a  : set client architecture (is guessed otherwise)
	    -c  : Solaris install cluster (e.g. SUNCuser)
	    -f  : list of finish scripts to run, comma separated. Can also 
	          be "all" or "none". If not supplied, any existing finish
	          script configuration for this client will be re-used
	    -F  : install from the named flash archive. Argument should be
	          supplied in ip_addr:/dir/file.flar form. Same OS should be 
	          supplied in <directory> as is in archive
	    -E  : force explicit partitioning for flash archive installation.
	          Normally "existing" slices are used
	    -R  : set client boot disk (e.g. c0t0d0)
	    -z  : use ZFS root
		-S  : size of ZFS root pool in GB (all disk if not supplied)
		-T  : if using ZFS root, swap size in GB (auto if not supplied)
	    -m  : install Solaris mirrored on the named disks (Sol 9 and later)
	    -p  : force creation of new client profile file
	    -s  : force creation of new client sysidcfg file
	    -u  : set up "update" profile
 
	EOUSAGE
	exit 2
}

apply_netmask()
{
	# Take a dot-decimal ip address and netmask and bitwise AND them to
	# return the network portion of the address

	for i in 1 2 3 4
	do
		IP[$i]=$(print $2 | cut -d . -f $i)
		MASK[$i]=$(print $1 | cut -d . -f $i)
	done

	for i in 1 2 3 4
	do
		NET[$i]=$((${IP[$i]} & ${MASK[$i]}))
	done

	print "${NET[1]}.${NET[2]}.${NET[3]}.${NET[4]}"
}

# NB -- the following make_ functions have the same interface.

function make_profile
{
	# Here we build a default profile. This won't work for all machines --
	# for a start c0 is often the DVD drive. So, you should create a profile
	# yourself and see this as a template to work from. Slice 3 is most
	# likely for a zpool, slice 7 for metadbs

	# $1 is the version of Solaris
	# $2 is the client config directory

	typeset PROF="${2}/profile"
	
	# If we've been asked to do an update, it's VERY easy to create the
	# profile. Note the early return. Sorry about that.

	if [[ -n $FORCE_UPDATE ]]
	then
		
		# If there's an existing profile and it looks like an install
		# profile, keep it.

		[[ -f $PROF ]] && egrep -s initial_install $PROF \
			&& mv $PROF .${PROF}.install

		print "install_type upgrade" >$PROF
		return
	fi

	# Flash archives require a different profile

	if [[ -n $FLAR ]]
	then
		cat <<-EOPROFILE >$PROF
			install_type            flash_install
			archive_location        nfs $FLAR

		EOPROFILE
	else
		cat <<-EOPROFILE >$PROF
			install_type    initial_install
			system_type     standalone
			cluster         $CLUSTER
	
		EOPROFILE
	fi
	
	# If we're doing a flash install and -E hasn't been supplied, we want to
	# use existing partitioning, so add that to the profile, and we're
	# finished. Please excuse the mid-function exit.

	if [[ -n $FLAR && -z $EXPLICIT ]]
	then
		print "partitioning		existing" >>$PROF
		return
	fi

	# On "modern" versions of Solaris, we can mirror the disks at jumpstart
	# time. Have we been asked to do that? We can even do ZFS now!

	if [[ -n $USE_ZFS ]]
	then

		# Are we mirroring? We have to give s0 rather than just the disk
		# name

		if [[ -n $MIRROR_DISKS ]]
		then
			zdsks="mirror $(print $MIRROR_DISKS | \
				sed 's/:/ /;s/\(d[0-9]\)/\1s0/g')"
		else
			zdsks=${ROOTDEV}s0
		fi

		# The root pool gets the whole disk; we auto size everything; we
		# call the root pool whatever's in $RPOOL; and the boot env
		# whatever's in $BE. Also, everything's in a single pool, so no
		# separate /var. This might change in future.  The keywords in the
		# pool line are:
		# pool pool_name pool_size swap_size dump_size

		cat <<-EOLAYOUT >>$PROF
			pool $RPOOL $RPOOLSIZE $SWAPSIZE auto $zdsks
			bootenv installbe bename $BE
		EOLAYOUT

	elif [[ -n $MIRROR_DISKS ]]
	then

		[[ ${1#*_} -lt 9 ]] \
			&& die "Jumpstart can't mirror disks on ${1}."

		# Check the disks we've been given look valid

		print $MIRROR_DISKS | tr ":" " " | read disk_1 disk_2

		cat <<-EOLAYOUT >>$PROF
			partitioning    explicit
			filesys mirror:d0 ${disk_1}s0 ${disk_2}s0       1024     /
			filesys mirror:d4 ${disk_1}s4 ${disk_2}s4       2048    swap
			filesys mirror:d5 ${disk_1}s5 ${disk_2}s5       1024    /var
			filesys mirror:d6 ${disk_1}s6 ${disk_2}s6       1024    /usr
			filesys ${disk_1}s3                             free
			filesys ${disk_2}s3                             free
			metadb  ${disk_1}s7 size 8192 count 4
			metadb  ${disk_2}s7 size 8192 count 4
		EOLAYOUT

	else

		cat<<-EOLAYOUT >>$PROF
			partitioning    explicit
			filesys ${ROOTDEV}s0        1024            /
			filesys ${ROOTDEV}s4        2048            swap
			filesys ${ROOTDEV}s5        1048            /var
			filesys ${ROOTDEV}s6        1024            /usr
			filesys ${ROOTDEV}s7        64
			filesys ${ROOTDEV}s3        free
		EOLAYOUT

	fi

	eval PKG_LIST='$'"ADD_PKG_$1"

	if [[ -n $PKG_LIST ]]
	then
		print

		for pkg in $PKG_LIST
		do
			print "package $pkg add"
		done

	fi >>$PROF
}

function make_sysidcfg
{
	# This function creates a default sysidcfg file for the client machine.
	# Sun keep changing the requirements of sysidcfg, so we have a different
	# one for each supported version of Solaris.

	# $1 is the version of Solaris
	# $2 is the client config directory

	case $1 in
	
		Solaris_2.6)
			cat <<-EOSYSIDCFG >$2/sysidcfg
			system_locale=en_UK
			root_password=$ROOT_PASSWD
			terminal=vt100
			network_interface=primary {netmask=$NETMASK
				  hostname=$CLIENT
				  ip_address=$CLIENT_IP}
			name_service=OTHER
			timezone=GB
			timeserver=localhost
			EOSYSIDCFG
			;;

		Solaris_2.7)
			cat <<-EOSYSIDCFG >$2/sysidcfg
				system_locale=en_GB
				terminal=xterm
				name_service=NONE
				timeserver=localhost
				root_password=$ROOT_PASSWD
			EOSYSIDCFG
			;;

		Solaris_8) 
			cat <<-EOSYSIDCFG >$2/sysidcfg
				system_locale=en_GB
				terminal=xterm
				network_interface=PRIMARY{protocol_ipv6=no
				  hostname=$CLIENT
				  ip_address=$CLIENT_IP
				  netmask=${NETMASK}}
				timezone=GB
				name_service=NONE
				timeserver=localhost
				security_policy=NONE
			EOSYSIDCFG
			;;

		Solaris_9)
			cat <<-EOSYSIDCFG >$2/sysidcfg
				system_locale=en_GB
				timezone=GB
				terminal=sun-cmd
				timeserver=localhost
				name_service=NONE
				root_password=$ROOT_PASSWD
				network_interface=primary {
				  hostname=$CLIENT
				  ip_address=$CLIENT_IP
				  netmask=$NETMASK
				  protocol_ipv6=no
				  default_route=$DEFAULT_ROUTE}
				security_policy=none
			EOSYSIDCFG
			;;

		Solaris_10)
			cat <<-EOSYSIDCFG >$2/sysidcfg
				system_locale=en_GB
				timezone=GB
				terminal=sun-cmd
				timeserver=localhost
				name_service=NONE
				root_password=$ROOT_PASSWD
				network_interface=primary {
				  hostname=$CLIENT
				  ip_address=$CLIENT_IP
				  netmask=$NETMASK
				  protocol_ipv6=no
				  default_route=$DEFAULT_ROUTE}
				security_policy=none
				nfs4_domain=dynamic
				auto_reg=disable
			EOSYSIDCFG
			;;

		Solaris_11)
			cat <<-EOSYSIDCFG >$2/sysidcfg
				system_locale=en_GB
				timezone=GB
				terminal=sun-cmd
				timeserver=localhost
				name_service=NONE
				root_password=$ROOT_PASSWD
				network_interface=primary {
				  hostname=$CLIENT
				  ip_address=$CLIENT_IP
				  netmask=$NETMASK
				  protocol_ipv6=no
				  default_route=$DEFAULT_ROUTE}
				security_policy=none
				nfs4_domain=dynamic
			EOSYSIDCFG
			;;

		*)	die "no sysidcfg"

	esac
}

function make_finish
{
	# Create a finish script. Normally this will just run our master.sh

	# $1 is the version of Solaris
	# $2 is the client config directory
	# FINISH_LIST is visible from the main script

	typeset FIN_FILE="${2}/finish"

	# If we're doing an upgrade, we don't want the finish scripts to be run,
	# because we assume they've already been run on the system. Watch out
	# for the early return!

	if [[ -n $FORCE_UPDATE ]]
	then
		cat <<-EOFINISH >$FIN_FILE
		#!/bin/sh
		echo "UPGRADE INSTALL. NOT RUNNING FINISH SCRIPTS!"

		EOFINISH
		return
	fi

	if [[ $FINISH_LIST == "none" ]]
	then
		rm -f $FIN_FILE
	elif [[ $FINISH_LIST == "all" ]]
	then
		cat <<-EOFINISH >$FIN_FILE
			#!/bin/sh

			\${SI_CONFIG_DIR}/bin/master.sh -D -a
		EOFINISH
	else
		# We've been given a list of finish scripts, which we'll write to a
		# file and reference through master.sh

		print $FINISH_LIST | tr "," "\n" >${2}/finish_scripts

		cat <<-EOFINISH >$FIN_FILE
			#!/bin/sh

			\${SI_CONFIG_DIR}/bin/master.sh -D -f \\
			"\${SI_CONFIG_DIR}/clients/\${CLIENT}/finish_scripts"
		EOFINISH
	fi

	[[ -s $FIN_FILE ]] && chmod 755 $FIN_FILE

	return 0
}

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE
 
# Get options

while getopts "a:c:Ef:F:m:npR:sS:T:uz" option 2>/dev/null
do

	case $option in 
		
		a)	ARCH=$OPTARG
			;;

		c)	CLUSTER=$OPTARG
			;;

		E)	EXPLICIT=true
			;;

		f)	FINISH_LIST=$OPTARG
			FORCE_FINISH=true
			;;

		F)	FLAR=$OPTARG
			;;

		m)	MIRROR_DISKS=$OPTARG
			;;

		p)	FORCE_PROFILE=true
			;;

		R)	ROOTDEV=$OPTARG
			;;

		S)	RPOOLSIZE=$OPTARG
			;;

		T)	SWAPSIZE=$OPTARG
			;;

		u)	FORCE_UPDATE=true
			;;

		s)	FORCE_SYSIDCFG=true
			;;

		z)	USE_ZFS=true
			;;

		*)	usage
			;;
	esac

done

shift $(( $OPTIND -1 ))

# Right number of args?

[[ $# == 2 ]] || usage

# Can't do FLAR upgrades right now

[[ -n $FORCE_UPDATE && -n $FLAR ]] \
	&& die "-u and -F options are mutually exclusive."

# If we've been asked to mirror disks, do the supplied devices look like
# they might be valid? Obviously, we can't check they exist on the client.

if [[ -n $MIRROR_DISKS ]]
then
	print $MIRROR_DISKS | \
	egrep -s "^c[0-9]+t[0-9]+d[0-9]+:c[0-9]+t[0-9]+d[0-9]$" \
		|| die "invalid format of -m option"
fi

# Some shorthand variables

IMG_DIR=$1
CLIENT=$2
CONF_DIR=${JS_CLIENT_BASE}/$CLIENT
CLIENT_MAC=$(sed -n "/[ 	]$CLIENT$/s/[ 	].*//p" /etc/ethers)
CLIENT_IP=$(sed -n -e "s/#.*$//" -e "/$CLIENT[	 ]*$/s/[	 ].*//p" \
/etc/inet/hosts)
SERVER_IP=""            # We auto-detect this below
DEFAULT_ROUTER=""       # We auto-detect this below
SOL_VER=$(ls $IMG_DIR | grep ^Solaris_)

# Is the client known to the server?

print -n "\nChecking client $CLIENT is configured\n\n          /etc/ethers: "

[[ -n $CLIENT_MAC ]] \
	&& print "ok [$CLIENT_MAC]" \
	|| { print "failed"; die "client not in /etc/ethers"; }

print -n "      /etc/inet/hosts: "

[[ -n $CLIENT_IP ]] \
	&& print "ok [$CLIENT_IP]" \
	|| { print "failed"; die "client not in /etc/inet/hosts"; }

# Is the image directory valid? 

[[ -d $IMG_DIR ]] \
	|| die "no image directory $1"

# We'll need to know our architecture later. If we haven't been given it,
# guess it

if [[ -z $ARCH ]]
then

	if [[ "$IMG_DIR" == *"/sparc/"* ]]
	then
		ARCH="sun4u"
	elif [[ "$IMG_DIR" == *"/x86/"* ]]
	then
		ARCH="i86pc"
		EXTRAS="-d"
	else
		die "client architecture unknown"
	fi

fi

# As we can install clients on multiple networks, we need to work out the
# right netmask, default router and js server ip address to give the client.
# We need to iterate through this jumpstart server's NICs to find one on the
# same network as the client.

ifconfig -a | sed '/^[a-z]/!d;/^lo/d;s/: .*//;/[0-9]:[0-9]/d' | \
while read if
do
	ifconfig $if | sed '2!d' | read a ipaddr b mask c

	# Convert this interface's hex netmask to dot-decimal form

	NETMASK=$(printf "%d.%d.%d.%d\n" $(print "$mask" | sed 's/../0x& /g'))

	SERVER_NET=$(apply_netmask ${NETMASK} ${ipaddr})
	CLIENT_NET=$(apply_netmask ${NETMASK} ${CLIENT_IP})

	# If the server and client networks match, we've found our server ip

	if [[ "$SERVER_NET" == "$CLIENT_NET" ]]
	then
		SERVER_IP=$ipaddr
		break
	fi

done

[[ -n $SERVER_IP ]] \
	|| die "this server has no interface on client's network"

# Now we know the netmask and correct network, we iterate through the
# available default routes, applying the netmask and comparing the result
# against the client net we found earlier.

netstat -rn | grep "^default" | \
while read default router blah
do
	ROUTER_NET=$(apply_netmask ${NETMASK} ${router})

	if [[ x$ROUTER_NET == x$CLIENT_NET ]]
	then
		DEFAULT_ROUTE=$router
		break
	fi

done

[[ -n $DEFAULT_ROUTE ]] \
	|| die "this server has no default route on the client's network"

# Everything looks good, so we can make a client config directory
 
mkdir -p $CONF_DIR \
	|| die "can't create client config directory [$CONF_DIR]"

# Find the relevant Solaris image Tools directory. I think I've run into
# trouble using one version's add_install_client with another version's
# image

TOOLS_DIR="${IMG_DIR}/${SOL_VER}/Tools"

[[ -d $TOOLS_DIR ]] \
	|| die "no Tools directory [$TOOLS_DIR]"

[[ -n $USE_ZFS ]] && RFS=Z || RFS=U
cat <<-EOINFO

client details

            hostname : $CLIENT
          IP address : $CLIENT_IP
       Solaris image : $IMG_DIR
    client directory : $CONF_DIR
        architecture : $ARCH
     Tools directory : $TOOLS_DIR
             root fs : ${RFS}FS
EOINFO

[[ -n $USE_ZFS ]] && cat <<-EOZINFO
       ZFS root pool : $RPOOL
  ZFS root pool size : $RPOOLSIZE
          swap space : $SWAPSIZE
    boot environment : $BE
EOZINFO

[[ -n $MIRROR_DISKS ]] \
	&& print "    boot disk mirror : $MIRROR_DISKS" \
	|| print "           boot disk : $ROOTDEV"


# If we've been given a list of finish scripts, look to see if they exist

if [[ -n $FINISH_LIST ]]
then

	if [[ $FINISH_LIST == "all" || $FINISH_LIST == "none" ]]
	then
		print "      finish scripts : ${FINISH_LIST}\n"
	else

		print "\nChecking finish scripts\n"
	
		print $FINISH_LIST | tr "," " " | while read fscr
		do
			TO_PRINT="$fscr"
			print -n "$TO_PRINT : "

			[[ -x $fscr ]] \
				&& print "ok" \
				|| { print "does not exist"; die "missing finish script."; }

		done
	
	fi

fi

# We may be re-installing an existing client, so things like sysidcfg and
# the profile might already exist. If they don't, or if we've been
# specifically asked to, create default ones.

typeset -u FORCE_VAR

for file in sysidcfg profile finish
do
	TO_PRINT="creating $file"
	FORCE_VAR="FORCE_$file"
	print -n "$TO_PRINT : "

	if [[ -f ${CONF_DIR}/$file ]] && eval [[ -z \$$FORCE_VAR ]]
	then
		print "already exists"
	else

		if make_$file $SOL_VER $CONF_DIR
		then
			print "ok"
		else
			print "failed"
			die "could not create ${CONF_DIR}/$file"
		fi

	fi

done

# Run add_install_client. You have to do this from its parent directory.
# That's shoddy, Sun.

cd $TOOLS_DIR \
	|| die "can't access add_install_client [$TOOLS_DIR]"

AIC_OUT="/tmp/aic_out.$$"
AIC_CMD="./add_install_client \
	$EXTRAS \
	-p ${SERVER_IP}:$CONF_DIR \
	-c ${SERVER_IP}:$JS_DIR \
	$CLIENT $ARCH"

print "Command executed:\n${AIC_CMD}\n\nOutput:\n" >$AIC_OUT

print -n "\nrunning 'add_install_client' : "

if $AIC_CMD >>$AIC_OUT 2>&1
then
	print "ok"
else
	print "failed. Debug info follows."
	cat $AIC_OUT
	rm $AIC_OUT
	exit 3
fi


# Normally we'd check the rules here, but if you're on an OpenSolaris
# variant, that won't work. So we hack it by simply adding our rule to
# rules.ok, and assuming we know what we're doing. Maybe one day I'll do
# this properly

whence pkg >/dev/null 2>&1 \
	&& RF="${JS_DIR}/rules.ok" \
	|| RF="${JS_DIR}/rules"

print "\nupdating ${RF##*/}"

# Update the rules file. Put this rule at the top

[[ -n $FINISH_LIST && $FINISH_LIST != "none" ]] \
	&& F_RULE="clients/${CLIENT}/finish" \
	|| F_RULE="-"

grep -v "^hostname $CLIENT" $RF >$TMPFILE
print "hostname $CLIENT	-	clients/${CLIENT}/profile	$F_RULE" >$RF
cat $TMPFILE >>$RF
rm -f $TMPFILE $AIC_OUT

# Check the rules file if we updated the proper one

if [[ $RF == "${JS_DIR}/rules" ]]
then

	# We are checking the rules file. Again, you need to be in the same
	# directory as it is

	cd $JS_DIR

	print "\nChecking rules file\n"

	./check
	XC=$?
fi

exit $XC
