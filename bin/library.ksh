#=============================================================================
#
# library.ksh
# -----------
#
# This script is not to be executed, merely sourced from other scripts. It
# provides a standard library of functions used by other scripts
#
#=============================================================================

#-----------------------------------------------------------------------------
# VARIABLES

LIB_VER="2.0"

#-----------------------------------------------------------------------------
# EXIT FUNCTIONS

function die
{
	# write the args to stdout and exit nonzero
	# $1 is the error message REMEMBER TO QUOTE IT!
	# $2 is the exit code. Optional

	print "ERROR: $1" | sed 's/^[ 	]*//g' | fold -w 80 >&2
	log ERROR "$1"
	exit ${2:-1}
}

#-----------------------------------------------------------------------------
# REPORTING FUNCTIONS

function ok
{
	# print ok. Just for shorthand in scripts

	print "ok"
}

function debug
{
	# print debugging output if the debug flag is set
	# $1 is the message REMEMBER TO QUOTE IT!

	[[ -n $DEBUG ]] && print "DEBUG: $1"
}

function log
{
	# write a message to the log file. LFILE must be defined at the top of
	# the including script
	# $1 is the severity
	# $2 is the message, REMEMBER TO QUOTE IT!

	print "$(date '+%d/%m/%y %H:%M:%S'):${1}:$2" >> $LFILE 2>/dev/null

}

function warn
{
	# print a warning message to standard error, and log
	# $1 is the message, as always REMEMBER TO QUOTE IT!

	print -u2 "WARNING: $1"
	log WARN "$1"
}

#-----------------------------------------------------------------------------
# FILESYSTEM FUNCTIONS

#-----------------------------------------------------------------------------
# HELP FUNCTIONS


function my_version
{
	# print the version of the script which calls the function

	print -n "${0##*/}: "
	[ "$MY_VER" ] && print "version $MY_VER" || print "unknown version"
}

function generic_info
{
	# just print information about the parent script

	cat <<-EOINFO
	 script version: $MY_VER
	library version: $LIB_VER
	EOINFO
}

#-----------------------------------------------------------------------------
# FORMATTING FUNCTIONS

function underline
{
	# print the given text, underlined

	print $* | sed -e 'p;s/./=/g'
}

function sunos_to_solaris
{
	# feed it a "uname -r" style SunOS version and it returns the
	# appropriate Solaris marketing version number

	# $1 is the version

	S_VER=${1#*.}

	[[ $S_VER < 7 ]] && S_VER="2.$S_VER"

	print "Solaris $S_VER"
}

function dir_to_sol
{
	# print the English name for an image named in the standard
	# 5.8-sparc format
	# $1 is the version
	# $2 is the architecture
	
	print $2 | egrep -s sparc && ARCH="SPARC" || ARCH="Intel"
	print "$(sunos_to_solaris $1) $ARCH"
}
	
#-----------------------------------------------------------------------------
# MISCELLANY

function get_conf_val
{

	# parse the configuration file and return the requested value
	# $1 is the section of the config file to parse
	# $2 is the value to get
	
	sed -e "/\[start $1\]/,/\[end $1\]/!d;s/[ 	]\{1,\}/ /g" \
	-e "s/[ 	]*#.*$//;/^[ ]*$2[ ]*=/!d;s/^[^=]*= *//" $CONF_FILE
}

function rand_str
{
	# prints a pseudo-random string combining the PID, the time and some
	# random numbers

	print "$$$(date "+%H%M%S%m")$RANDOM"

}
