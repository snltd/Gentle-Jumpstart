#!/bin/ksh

#=============================================================================
#
# install_from_iso.sh
# -------------------
#
# This script is a big fancy wrapper to setup_install_server and
# add_to_install_server. That is, it makes Jumpstart  directories from
# Solaris install CDs and DVDs.  It has the ability to install full sets of
# CDs in one go, handles multiple revisions of the same Solaris versions, is
# SPARC and x86 compatible, and works with all Solarises from 2.1 to SXCE
# inclusive. (As far as I know. There's a list of tested versions below.)
#
# By default, images are installed into /js/export/arch/version where "arch"
# is x86 or sparc, and "verion" is derived from the .iso filename. The
# "/js/export" part can be overriden with the -R option, and a target
# directory can be explicitly specified with -d.
#
# Run with -h for full usage information.
#
# -a option will only recognize files called sol*.iso.*
#
# No dependencies.
#
# Tested on SPARC and x86 Jumpstart servers with the following Solaris ISOs.
# (CD images unless otherwise stated, all releases > 7 are full multi-CD
# installs.) 
#  SPARC: 2.1; 2.2; 2.3; 2.4; 2.6 OE, HW3; 7 FSC, 09/98, 11/99; 8 U7, HW3,
#         HW4; 9 U8 (DVD); 10 GA (DVD), U6 (DVD)
#  x86: 7 09/98a; 8u7; 10 GA, U7 (DVD); Nevada b129

# Solaris 10GA and earlier images cannot be installed onto a ZFS filesystem
# without modifying the setup_install_server script, which I don't
# recommend.  For instructions on how to build a ZFS based Jumpstart server
# which can accomodate these versions of Solaris please refer to
#  http://www.snltd.co.uk/snippets/index.php?c=v&sn=jumpstart_zfs.php
#
# $1 is the image to install
#
# v1.0 Initial release RDF 10/06
#
# v1.1 Adapted to use a different mount point for each different CD in a
#      sequence 08/08/08 RDF
#
# v2.0 Pretty much rewritten. Far better location of image files with -a and
#      -s options. Checks for lofi capability. New -R option to install in
#      alternative root (useful installing < 5.9 onto a UFS filesystem on a
#      ZFS Solaris 10+.) Read VTOC ourselves, rather than relying on
#      architecture specific third-party binary. Check target filesystem is
#      of a suitable type. Better annotation. -V option to print version.
#	   -d option to force target directory.  Fit for public consumption. RDF
#	   18/04/10.
#
#=============================================================================

#-----------------------------------------------------------------------------
# VARIABLES

TMP_DIR="/js/tmp"
	# this may have to hold an unpacked DVD image, so it needs pleny of room

MNT_PT="${TMP_DIR}/mnt"
	# The base for the temporary loopback mounts

JS_IMG_DIR="/js/export/images"
	# Default root of Jumpstart images

ERR_LOG="$(mktemp -p $TMP_DIR)"
	# Catch setup_install_client errors here

MY_VER="2.0"
	# Version of script. Keep updated!

#-----------------------------------------------------------------------------
# FUNCTIONS

function usage
{
	# How to use the script

	cat <<-EOHELP

	usage:
	
	  ${0##*/} -a [-d dir] [-i sparc|x86] [-R dir] directory
	  ${0##*/} -s [-d dir] [-i sparc|x86] [-R dir] image_file(s)
	  ${0##*/} [-d dir] [-i sparc|x86] [-R dir] image_file(s)
	  ${0##*/} -V

	  -a : install all .iso files in the given directory

	  -d : specify target directory

	  -s : install other CD images belonging to same set as given file

	  -i : if architecture cannot be determined from filename, use the
	       supplied argument

	  -R : root of Jumpstart installs (default is ${JS_IMG_DIR})

	  -V : print version and exit

	EOHELP
	exit 2
}

function die
{
	# Print error message, clean up, and exit
	# $1 is error message
	# $2 is optional exit code. Exits 1 if not supplied

	print -u2 "\nERROR: $1"

	if [[ -s $ERR_LOG ]]
	then
		print "\nError log follows:\n"
		cat $ERR_LOG
	fi

	clean_up
	exit ${2:-1}
}

function full_path
{
	# get the full path to the given file
	# $1 is the file

	if [[ "$1" == "/"* ]]
	then
		print $1
	elif [[ "$1" == */* ]]
	then
		print "$(cd ${1%/*}; print $PWD)/${1##*/}" 
	else
		print "$(pwd)/$1"
	fi
}

function clean_up
{
	# Clean up after ourselves

	cd $MYDIR
	print -u2 "\nCleaning up."
	clean_loopbacks $IMGS $XTRA_LOFS
	rm -f $ERR_LOG $XTRA_RM
	rmdir -p $MNT_S1 $MNT_S2 2>/dev/null
}

function clean_loopbacks
{
	# If any of the images we're working on are already loopback mounted,
	# clean up. Args are image files

	lofiadm | egrep "$(print $* | tr " " "|")" | while read ldev im opt
	do
		unset mpt
		print "$im exists as $ldev. Clearing."
		mpt=$(df -k $ldev 2>/dev/null | sed 1d)

		[[ -n $mpt ]] && umount ${mpt##* }

		lofiadm -d $ldev
	done
}

function check_valid_file
{
	# Check the supplied file looks like a suitable ISO image.
	# $1 is a fully qualified path to a file

	ret=0

	if [[ ! -f $1 ]]
	then
		print -u2 "WARNING: $f is not a file."
		ret=1
	elif [[ ${file##*/} != *.iso* ]]
	then
		print -u2 "WARNING: $f does not look like an ISO image."
		ret=1
	fi

	return $ret
}

function unpack_image
{
	# unpack a .gz, .bz2 or a .zip iso file and print the name
	# $1 is the file to unpack

	sfx=${1##*.}

	if [[ $sfx == "zip" ]]
	then
		# get the name of the zipped file. zip sucks
		unzip -l $1 | grep '\.iso' | read junk junk junk NAME
		unzip -o -qq $1 -d $TMP_DIR || return 1
		OUT=${TMP_DIR}/${NAME##*/}
	elif [[ $sfx == "bz2" ]]
	then
		NAME=${1%.bz2}
		OUT="${TMP_DIR}/${NAME##*/}"
		bzip2 -dc $1 >$OUT || return 1
	elif [[ $sfx == "gz" ]]
	then
		NAME=${1%.gz}
		OUT="${TMP_DIR}/${NAME##*/}"
		gzip -dc $1 >$OUT || return 1
	fi

	print $OUT
}

function mount_img
{
	# Mount a 
	# $1 is the image file
	# $2 is the mountpoint
	# $3 is the fs type. Defaults to HSFS

	lfdev=$(lofiadm -a $1 2>/dev/null)

	if [[ -z $lfdev ]]
	then
		print -u2 "ERROR: Could not create lofi device."
		return 1
	fi

	print -u2 "  created loopback device. [${lfdev}]"
	mkdir -p $2

	if ! mount -oro -F${3:-hsfs} $lfdev $2
	then
		print -u2 "ERROR: Could not mount device. [${2}]"
		return 1
	fi
}

#-----------------------------------------------------------------------------
# SCRIPT STARTS HERE

# If the user stops us, clean up

trap 'clean_up' INT

# We have to cd into the loopback mounted image to run setup_install_client,
# then get out of it when we clean up. We'll go back to where we started.
# (But not use cd - because clean up can happen at any point in the script.)

MYDIR=$(pwd)

# Do we have any options?

while getopts ad:i:R:sV option 2>/dev/null
do
    case $option in
	
		a)	INSTALL_ALL=true
			;;
		
		d)	TARGET_DIR=$OPTARG
			;;

		i)	FORCE_ARCH=$OPTARG
			;;
		
		R)	JS_IMG_DIR=$OPTARG
			;;

		s)	INSTALL_SEQ=true
			;;
		
		V)	print $MY_VER
			exit
			;;

		*)	usage
			;;
	esac

done 2>/dev/null

shift $(($OPTIND - 1))

# We need to be able to mount lofi devices.

[[ -a /dev/lofictl ]] || die "no /dev/lofictl. (In local zone?)"

# We also need arguments

(( $# == 0 )) && usage

# Make a list of the files we're going to process and store it in IMGS

if [[ -n $INSTALL_ALL ]]
then

	# We've been asked to install every ISO image in a directory. Check that
	# directory exists, then get a list of isos in in. Also look for
	# compressed ones.

	(( $# == 1)) || die "-a requires a single directory."

	dir=$(full_path $1)
	
	[[ -d $dir ]] || die "Directory does not exist."

	print "Installing all ISO images in ${dir}."
	IMGS=$(find ${dir}/* -prune -a -type f -name sol\*.iso\*)
elif [[ -n $INSTALL_SEQ ]]
then

	# We've been asked to install a sequence of images. Work out from the
	# supplied filename what other files should be called. We expect "v1" to
	# be in the filename
	
	IMGS=$(for f
	do
		# Fully qualify the file path, check it looks okay, then make sure
		# it looks like the first in a sequence

		file=$(full_path $f)
		fn=${file##*/}

		check_valid_file $file || continue

		if [[ $fn != *v1* ]]
		then
			print -u2 \
			"WARNING: $fn does not look like first in a sequence of files."
			continue
		fi

		ls ${file%/*}/$(print $fn | sed 's/v1/v[0-9]/')
	done)

else
	# We're just installing the supplied ISO files. Check they look okay.

	IMGS=$(for f
	do
		file=$(full_path $f)
		check_valid_file $file && print $file || continue
	done)

fi

# Print a nicely formatted list of ISO images we're going to install, or
# exit.

if [[ -n $IMGS ]]
then
	print "\nFound images:"
	print $IMGS | tr " " "\n" | sed 's/^.*\//  /'
else
	print "No images found. Exiting."
	exit 3
fi

# If the user specified ISO images with ./, there will be /./s in the paths
# to them. Remove those.

IMGS=$(print $IMGS | sed 's|/./|/|g')

# Make the temporary directory

mkdir -p $TMP_DIR

# Look through each file

for img in $IMGS 
do
	iname=${img##*/}
	sfx=${iname##*.}
	print "\nExamining ${iname}."

	# Try to work out the architecture and version of Solaris

	if [[ $iname == *sparc* ]]
	then
		ARCH="sparc"
	elif [[ $iname == *x86* ]]
	then
		ARCH="x86"
	elif [[ $iname == *ia* ]] 
	then

		# Sun used to denote Intel versions with "ia", then later "x86". We
		# split on that string later. So use PARCH to store it.

		ARCH="x86"
		PARCH="ia"
	else

		if [[ -n $FORCE_ARCH ]]
		then
			print -u2 \
			"Installing as a ${FORCE_ARCH} image."
			ARCH=$FORCE_ARCH
		else
			print -u2 \
			"WARNING: Can't work out the architecture of ${iname}. Skipping."
			continue
		fi

	fi

	# is the image compressed? If it is, call a function to uncompress it.
	# We can handle .zip, .gz, and .bz2. Add the uncompressed image to the
	# XTRA_RM variable so it gets cleaned up later.

	if [[ $sfx == "bz2" || $sfx == "gz" || $sfx == "zip" ]]
	then
		print -n "  unpacking image to ${TMP_DIR}: "
		img=$(unpack_image $img) && print "ok" || die "failed"
		XTRA_RM="$XTRA_RM $img"
		XTRA_LOFS="$XTRA_LOFS $img"
	fi

	# If the INST_DIR if it was specified, use it. If not try to work out
	# where the image should go

	if [[ -n $TARGET_DIR ]]
	then
		INST_DIR=$TARGET_DIR
	else

		# Get the version by grabbing the bit between sol- and
		# -architecture.  Then we know where we're installing to. Have a
		# stab at working out a sensible directory name. If that fails,
		# you'll just get the name of the original ISO file. In that case,
		# chop .iso off the end

		PARCH=${PARCH:-$ARCH}
		VER=${iname#sol[-_]}
		INST_DIR="${JS_IMG_DIR}/${ARCH}/${VER%[-_]$PARCH*}"

		[[ $INST_DIR == *.iso ]] && INST_DIR=${INST_DIR%.iso}

		mkdir -p $INST_DIR
	fi

	print "\nInstalling to $INST_DIR"

	# Make sure we don't have loopbacks already using the image we're
	# interested in.

	clean_loopbacks $img

	# Now we can mount the image and do the install. Old versions and all
	# DVDs are simple, you just mount the whole thing, i.e. Slice 2.
	# Solaris 9, however, is awkward. They put the Product/ directory on
	# slice 2, and the bootable part on slice 1. Our problem is that the
	# binaries needed to do the server install are also on slice 1. We don't
	# need to remove half-complete mounts; it all gets done by clean_up()

	MNT_BASE="${MNT_PT}/${iname%.iso*}"
	MNT_S2="${MNT_BASE}/s2"

	print "  mounting image (${img})."

	mount_img $img $MNT_S2 \
		&& print -u2 "  mounted. [${MNT_S2}]" \
		|| continue

	# Get the Solaris version

	SOL_VER=$(ls $MNT_S2 2>/dev/null | grep ^Solaris_)

	if [[ -z $SOL_VER ]]
	then
		print -u2 "ERROR: This appears not to be a Solaris install CD."
		continue
	fi

	print "  found $SOL_VER image"

	# Look for the relevant setup file. First look for
	# add_to_install_server. You used to get this on the multi-CD releases
	# of 8-10. Then look for setup_install_server. You get that in a couple
	# of different locations.

	ATIS="${MNT_S2}/${SOL_VER}/Tools/add_to_install_server"
	SIS1="${MNT_S2}/${SOL_VER}/Tools/setup_install_server"
	SIS2="${MNT_S2}/setup_install_server"

	if [[ -f $ATIS ]]
	then

		if [[ -d $INST_DIR ]]
		then
			print -n \
			"  found add_to_install_server.\n  adding image to ${INST_DIR}: "

			$ATIS $INST_DIR >>$ERR_LOG 2>&1 && print "ok" || die "failed"
		else
			print -u2 \
			"ERROR: found add_to_install_server but target does not exist."
		fi

		# Whether it's there or not, we're done for this iteration.

		continue

	elif [[ -f $SIS1 ]]
	then
		SIS=$SIS1
	elif [[ -f $SIS2 ]]
	then
		SIS=$SIS2
	else
		print -u2 \
		"ERROR: cannot find setup_install_server or add_to_install_server."
		continue
	fi

	# Is the target directory empty? The install will fail if not, but it'll
	# take a while

	if [[ -d $INST_DIR ]] && [ $(ls $INST_DIR | wc -l) != 0 ]
	then
		print -u2 "ERROR: target directory is not empty. [${INST_DIR}]"
		continue
	fi

	print "  found setup_install_server"

	
	# For some stupid reason (probably to do with space), Sun put the
	# Solaris 9 and 10 Product data on slice 2 of install CDs, and the boot
	# environment on slice 1. Is this one of those disks?
	
	if [[ -L "${MNT_S2}/${SOL_VER}/Tools/Boot" ]]
	then
		print "  separate slice 1 required"

		# Yes, so we need to cut slice 1 it out of the ISO image with dd.
		# But, since we need to mount slice 1, which holds a UFS filesystem,
		# we can only process SPARC CDs on SPARC, and x86 on x86.

		MY_ARCH=$(uname -p)
		[[ $MY_ARCH == "i386" ]] && MY_ARCH="x86"

		if [[ $MY_ARCH != $ARCH ]]
		then
			print "ERROR: cannot process $ARCH CDs on a $MY_ARCH system."
			continue
		fi

		# We're good to go. We need a couple of temp files and somewhere to
		# mount slice 1

		S1_IMG=$(mktemp -p $TMP_DIR)
		MNT_S1="${MNT_BASE}/s1"
		TMP_VTOC="$(mktemp -p $TMP_DIR)"

		# We'll need to clean up the temporary image and mountpoint too

		#XTRA_LOFS="$XTRA_LOFS $S1_IMG"
		#XTRA_RM="$XTRA_RM $S1_IMG $TMP_VTOC"
	
		# Now it's time to cut a chunk out of the ISO. I got the general
		# method for this from
		# http://www.docbert.org/Solaris/Jumpstart/Sol9/Sol9EA-iso.html
		# then adapted it so it would work on little endian x86 as well as
		# big-endian SPARC.

		dd if=$img of=$TMP_VTOC bs=512 count=1 2>/dev/null
		od -tx1 -j 452 -N 8 < $TMP_VTOC | sed 1q | read a b c d e f g h i

		b1=0
		b2=$(printf %d 0x$b$c$d$e)
		b3=$(printf %d 0x$f$g$h$i)

		if [[ $ARCH == "sparc" ]] 
		then
			skipb=$b2
			count=$b3
		else
			skipb=0
			count=$b2
		fi

		dd if=$img of=$S1_IMG bs=512 skip=$(print $skipb \* 640 | bc) \
		count=$count >/dev/null

		print "Mounting slice 1."

		mount_img $S1_IMG $MNT_S1 ufs \
			&& print -u2 "  mounted. [${MNT_S1}]" \
			|| continue

	fi
			
	print -n "  installing image in $INST_DIR: "

	# You have to cd into the setup_install_server directory and run it from
	# there. That's pretty weak. 

	cd ${SIS%/*}
	./${SIS##*/} $INST_DIR >>$ERR_LOG 2>&1 && print "ok" || die "failed"
done

clean_up

