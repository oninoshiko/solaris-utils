#!/usr/bin/ksh
#
# nfsvsvrtop - display top NFS v3 & v4 I/O events on a server.
#
# This is measuring the response time between an incoming NFS operation
# and its response. In general, this measures the server's view of how
# quickly it can respond to requests. By default, the list shows responses
# to each client.
# 	
# Top-level fields:
#	load	1 min load average
#	read	total KB read during sample
#	swrite	total KB sync writes during sample
#	awrite	total KB async writes during sample
#
# The following per-client and "all" clients fields are shown
#	Ver     NFS version (3 or 4)
#	Client	IP addr of client
#	NFSOPS	NFS operations per second
#	Reads	Read operations per second
#	SWrites Sync write operations per second
#	AWrites Async write operations per second
#	Commits	Commits per second
#	Rd_bw	Read KB/sec
#	SWr_bw	Sync write KB/sec
#	AWr_bw	Async write KB/sec
#	Rd_t	Average read time in microseconds
#	SWr_t   Average sync write time in microseconds
#	AWr_t   Average async write time in microseconds
#	Com_t	Average commit time in microseconds
#
# Note: NFSv4 compound operations are not measured, per se, but they are
# counted in the total operations count.
#
# Note: dtrace doesn't do floating point. A seemingly zero response or 
# count can result due to integer division.
# 
#
# INSPIRATION:  top(1) by William LeFebvre and iotop by Brendan Gregg
#
# Copyright 2011, Nexenta Systems, Inc. All rights reserved.
#
# CDDL HEADER START
#
#  The contents of this file are subject to the terms of the
#  Common Development and Distribution License, Version 1.0 only
#  (the "License").  You may not use this file except in compliance
#  with the License.
#
#  You can obtain a copy of the license at Docs/cddl1.txt
#  or http://www.opensolaris.org/os/licensing.
#  See the License for the specific language governing permissions
#  and limitations under the License.
#
# CDDL HEADER END
#
# Author: Richard.Elling@Nexenta.com
#
# Revision:
#   1.2	6-Jun-2011
#
# TODO: running count of nfsd threads (done efficiently)
# TODO: mount point filter

##############################
# --- Process Arguments ---
#

### default variables
opt_client=0	# set if -c option set
opt_clear=1		# set if screen to be cleared
opt_top=0		# set if list trimmed to top
top=0			# number of lines trimmed
opt_vers=0		# set if NFS version restricted
vers=3			# version of NFS to restrict
interval=10		# default interval
count=-1		# number of intervals to show

### process options
while getopts c:Cm:n:t: name
do
	case $name in
	c)	opt_client=1; client_IP=$OPTARG ;;
	C)	opt_clear=0 ;;
	n)	opt_vers=1; vers=$OPTARG ;;
	t)	opt_top=1; top=$OPTARG ;;
	h|?)	cat <<-END >&2
		USAGE: nfssvrtop [-C] [-c client_IP] [-t top] [interval [count]]
						-c client_IP	# trace for this client only
		                -C      # don't clear the screen
		                -t top  	# print top number of entries only
		   eg,
		        nfssvrtop       # default output, 10 second samples
		        nfssvrtop 1     # 1 second samples
				nfssvrtop -n 4	# only show NFSv4 traffic
		        nfssvrtop -C 60 # 60 second samples, do not clear screen
		        nfssvrtop -t 20 # print top 20 lines only
		        nfssvrtop 5 12  # print 12 x 5 second samples
		END
		exit 1
	esac
done

shift $(($OPTIND - 1))

### option logic
if [ ! -z "$1" ]; then
        interval=$1; shift
fi
if [ ! -z "$1" ]; then
        count=$1; shift
fi
if [ $opt_clear = 1 ]; then
        clearstr=$(clear)
else
        clearstr=""
fi



#################################
# --- Main Program, DTrace ---
#
/usr/sbin/dtrace -n '
/*
 * Command line arguments
 */
inline int OPT_client	= '$opt_client';
inline int OPT_clear 	= '$opt_clear';
inline int OPT_top 	= '$opt_top';
inline int OPT_vers	= '$opt_vers';
inline int INTERVAL 	= '$interval';
inline int COUNTER 	= '$count';
inline int TOP 	= '$top';
inline string CLIENT	= "'$client_IP'";
inline int VERS	= '$vers';
inline string CLEAR 	= "'$clearstr'";

#pragma D option quiet

/* increase dynvarsize if you get "dynamic variable drops" */
#pragma D option dynvarsize=8m

/*
 * Print header
 */
dtrace:::BEGIN 
{
	/* starting values */
	counts = COUNTER;
	secs = INTERVAL;
	total_read_b = 0;
	total_swrite_b = 0;
	total_awrite_b = 0;

	printf("Tracing... Please wait.\n");
}

/*
 * Filter as needed, based on starts
 */
nfsv3:nfssrv::op-access-start,
nfsv3:nfssrv::op-create-start,
nfsv3:nfssrv::op-commit-start,
nfsv3:nfssrv::op-fsinfo-start,
nfsv3:nfssrv::op-fsstat-start,
nfsv3:nfssrv::op-getattr-start,
nfsv3:nfssrv::op-link-start,
nfsv3:nfssrv::op-lookup-start,
nfsv3:nfssrv::op-mkdir-start,
nfsv3:nfssrv::op-mknod-start,
nfsv3:nfssrv::op-null-start,
nfsv3:nfssrv::op-pathconf-start,
nfsv3:nfssrv::op-read-start,
nfsv3:nfssrv::op-readdir-start,
nfsv3:nfssrv::op-readdirplus-start,
nfsv3:nfssrv::op-readlink-start,
nfsv3:nfssrv::op-remove-start,
nfsv3:nfssrv::op-rename-start,
nfsv3:nfssrv::op-rmdir-start,
nfsv3:nfssrv::op-setattr-start,
nfsv3:nfssrv::op-symlink-start,
nfsv3:nfssrv::op-write-start
/OPT_client == 0 || CLIENT == args[0]->ci_remote/
{ 
	self->vers = "3";
	@c_nfsops[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_nfsops[self->vers, "all"] = count() : 1;
}

nfsv4:nfssrv::cb-recall-start,
nfsv4:nfssrv::compound-start,
nfsv4:nfssrv::null-start,
nfsv4:nfssrv::op-access-start,
nfsv4:nfssrv::op-close-start,
nfsv4:nfssrv::op-commit-start,
nfsv4:nfssrv::op-create-start,
nfsv4:nfssrv::op-delegpurge-start,
nfsv4:nfssrv::op-delegreturn-start,
nfsv4:nfssrv::op-getattr-start,
nfsv4:nfssrv::op-getfh-start,
nfsv4:nfssrv::op-link-start,
nfsv4:nfssrv::op-lock-start,
nfsv4:nfssrv::op-lockt-start,
nfsv4:nfssrv::op-locku-start,
nfsv4:nfssrv::op-lookup-start,
nfsv4:nfssrv::op-lookupp-start,
nfsv4:nfssrv::op-nverify-start,
nfsv4:nfssrv::op-open-confirm-start,
nfsv4:nfssrv::op-open-downgrade-start,
nfsv4:nfssrv::op-open-start,
nfsv4:nfssrv::op-openattr-start,
nfsv4:nfssrv::op-putfh-start,
nfsv4:nfssrv::op-putpubfh-start,
nfsv4:nfssrv::op-putrootfh-start,
nfsv4:nfssrv::op-read-start,
nfsv4:nfssrv::op-readdir-start,
nfsv4:nfssrv::op-readlink-start,
nfsv4:nfssrv::op-release-lockowner-start,
nfsv4:nfssrv::op-remove-start,
nfsv4:nfssrv::op-rename-start,
nfsv4:nfssrv::op-renew-start,
nfsv4:nfssrv::op-restorefh-start,
nfsv4:nfssrv::op-savefh-start,
nfsv4:nfssrv::op-secinfo-start,
nfsv4:nfssrv::op-setattr-start,
nfsv4:nfssrv::op-setclientid-confirm-start,
nfsv4:nfssrv::op-setclientid-start,
nfsv4:nfssrv::op-verify-start,
nfsv4:nfssrv::op-write-start
/OPT_client == 0 || CLIENT == args[0]->ci_remote/
{ 
	self->vers = "4";
	@c_nfsops[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_nfsops[self->vers, "all"] = count() : 1;
}

/* measure response time for commits, reads, and writes */
nfsv3:nfssrv::op-commit-start,
nfsv3:nfssrv::op-read-start,
nfsv3:nfssrv::op-write-start,
nfsv4:nfssrv::op-commit-start,
nfsv4:nfssrv::op-read-start,
nfsv4:nfssrv::op-write-start
/OPT_client == 0 || CLIENT == args[0]->ci_remote/
{ 
	self->startts = timestamp;
}


/*
 * commit 
 */
nfsv3:nfssrv::op-commit-start,
nfsv4:nfssrv::op-commit-start
/self->startts/
{
	@c_commit_client[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_commit_client[self->vers, "all"] = count() : 1;
}

nfsv3:nfssrv::op-commit-done,
nfsv4:nfssrv::op-commit-done
/self->startts/
{
	t = timestamp - self->startts;
	@avgtime_commit[self->vers, args[0]->ci_remote] = avg(t);
	OPT_client == 0 ? @avgtime_commit[self->vers, "all"] = avg(t) : 1;
	self->startts = 0;
}

/*
 * read
 */
nfsv3:nfssrv::op-read-start,
nfsv4:nfssrv::op-read-start
/self->startts/
{
	@c_read_client[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_read_client[self->vers, "all"] = count() : 1;
	@read_b[self->vers, args[0]->ci_remote] = sum(args[2]->count);
	OPT_client == 0 ? @read_b[self->vers, "all"] = sum(args[2]->count) : 1;
	total_read_b += args[2]->count;
}

nfsv3:nfssrv::op-read-done,
nfsv4:nfssrv::op-read-done
/self->startts/
{
	t = timestamp - self->startts;
	@avgtime_read[self->vers, args[0]->ci_remote] = avg(t);
	OPT_client == 0 ? @avgtime_read[self->vers, "all"] = avg(t) : 1;
	self->startts = 0;
}

/*
 * write (sync)
 */
nfsv3:nfssrv::op-write-start
/self->startts && args[2]->stable/
{
	self->issync = 1;
	data_len = args[2]->data.data_len;
	@c_swrite_client[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_swrite_client[self->vers, "all"] = count() : 1;
	@swrite_b[self->vers, args[0]->ci_remote] = sum(data_len);
	OPT_client == 0 ? @swrite_b[self->vers, "all"] = sum(data_len) : 1;
	total_swrite_b += data_len;
}

nfsv4:nfssrv::op-write-start
/self->startts && args[2]->stable/
{
	self->issync = 1;
	data_len = args[2]->data_len;
	@c_swrite_client[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_swrite_client[self->vers, "all"] = count() : 1;
	@swrite_b[self->vers, args[0]->ci_remote] = sum(data_len);
	OPT_client == 0 ? @swrite_b[self->vers, "all"] = sum(data_len) : 1;
	total_swrite_b += data_len;
}

nfsv3:nfssrv::op-write-done,
nfsv4:nfssrv::op-write-done
/self->startts && self->issync/
{
	t = timestamp - self->startts;
	@avgtime_swrite[self->vers, args[0]->ci_remote] = avg(t);
	OPT_client == 0 ? @avgtime_swrite[self->vers, "all"] = avg(t) : 1;
	self->startts = 0;
}

/*
 * write (async)
 */
nfsv3:nfssrv::op-write-start
/self->startts && !args[2]->stable/
{
	self->issync = 0;
	data_len = args[2]->data.data_len;
	@c_awrite_client[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_awrite_client[self->vers, "all"] = count() : 1;
	@awrite_b[self->vers, args[0]->ci_remote] = sum(data_len);
	OPT_client == 0 ? @awrite_b[self->vers, "all"] = sum(data_len) : 1;
	total_awrite_b += data_len;
}

nfsv4:nfssrv::op-write-start
/self->startts && !args[2]->stable/
{
	self->issync = 0;
	data_len = args[2]->data_len;
	@c_awrite_client[self->vers, args[0]->ci_remote] = count();
	OPT_client == 0 ? @c_awrite_client[self->vers, "all"] = count() : 1;
	@awrite_b[self->vers, args[0]->ci_remote] = sum(data_len);
	OPT_client == 0 ? @awrite_b[self->vers, "all"] = sum(data_len) : 1;
	total_awrite_b += data_len;
}

nfsv3:nfssrv::op-write-done,
nfsv4:nfssrv::op-write-done
/self->startts && !self->issync/
{
	t = timestamp - self->startts;
	@avgtime_awrite[self->vers, args[0]->ci_remote] = avg(t);
	OPT_client == 0 ? @avgtime_awrite[self->vers, "all"] = avg(t) : 1;
	self->startts = 0;
}

/*
 * timer
 */
profile:::tick-1sec
{
	secs--;
}

/*
 * Print report
 */
profile:::tick-1sec
/secs == 0/
{	
	/* fetch 1 min load average */
	self->load1a  = `hp_avenrun[0] / 65536;
	self->load1b  = ((`hp_avenrun[0] % 65536) * 100) / 65536;

	/* convert counters to Kbytes */
	total_read_b /= 1024;
	total_swrite_b /= 1024;
	total_awrite_b /= 1024;

	/* normalize to seconds giving a rate */
	/* todo: this should be measured, not based on the INTERVAL */
	normalize(@c_nfsops, INTERVAL);
	normalize(@c_read_client, INTERVAL);
	normalize(@c_swrite_client, INTERVAL);
	normalize(@c_awrite_client, INTERVAL);
	normalize(@c_commit_client, INTERVAL);
	
	/* normalize to KB per second */
	normalize(@read_b, 1024 * INTERVAL);
	normalize(@awrite_b, 1024 * INTERVAL);
	normalize(@swrite_b, 1024 * INTERVAL);
	
	/* normalize average to microseconds */
	normalize(@avgtime_read, 1000);
	normalize(@avgtime_swrite, 1000);
	normalize(@avgtime_awrite, 1000);
	normalize(@avgtime_commit, 1000);

	/* print status */
	OPT_clear ? printf("%s", CLEAR) : 1;
	printf("%Y, load: %d.%02d, read: %6d KB, swrite: %6d KB, awrite: %6d KB\n",
	    walltimestamp, self->load1a, self->load1b, 
		total_read_b, total_swrite_b, total_awrite_b);

	/* print headers */
	printf("%s\t%-15s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\t%7s\n",
	    "Ver", "Client", "NFSOPS", 
		"Reads", "SWrites", "AWrites", "Commits",
		"Rd_bw", "SWr_bw", "AWr_bw",
		"Rd_t", "SWr_t", "AWr_t", "Com_t");

	/* truncate to top lines if needed */
	OPT_top ? trunc(@c_nfsops, TOP) : 1;

	printa("%s\t%-15s\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\t%7@d\n",
		@c_nfsops, @c_read_client, @c_swrite_client, @c_awrite_client, @c_commit_client,
		@read_b, @swrite_b, @awrite_b,
		@avgtime_read, @avgtime_swrite, @avgtime_awrite,
		@avgtime_commit);

	/* clear data */
	trunc(@c_nfsops); trunc(@c_read_client); trunc(@c_swrite_client); trunc(@c_awrite_client);
	trunc(@c_commit_client);
	trunc(@read_b); trunc(@awrite_b); trunc(@swrite_b);
	trunc(@avgtime_read); trunc(@avgtime_swrite); trunc(@avgtime_awrite); trunc(@avgtime_commit);
	total_read_b = 0;
	total_swrite_b = 0;
	total_awrite_b = 0;
	secs = INTERVAL;
	counts--;
}

/*
 * end of program 
 */
profile:::tick-1sec
/counts == 0/
{
	exit(0);
}

/*
 * clean up when interrupted
 */
dtrace:::END
{
	trunc(@c_nfsops); trunc(@c_read_client); trunc(@c_swrite_client); trunc(@c_awrite_client);
	trunc(@c_commit_client);
	trunc(@read_b); trunc(@awrite_b); trunc(@swrite_b);
	trunc(@avgtime_read); trunc(@avgtime_swrite); trunc(@avgtime_awrite); trunc(@avgtime_commit);
}
'
