#! /usr/bin/ksh -p
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
# Portions Copyright 2009 Sun Microsystems, Inc.
# Portions Copyright 2009 Richard Elling
#
# File: zilstat.ksh
# Author: Richard.Elling@RichardElling.com
# Online information:
# http://www.RichardElling.com/Home/scripts-and-programs-1/zilstat-intro
#
# This dtrace program will help identify the ZIL activity by sampling
# writes sent to the ZIL.
# output:
# [TIME]
# Bytes - total bytes written to ZIL over the interval
# Bytes/S - bytes/s written to ZIL over ther interval
# Max-Rate - maximum rate during any 1-second sample
# this output is listed for both the size of the data and the
# size of the buffer containing the data.
# In an attempt to reconcile writes > zfs_immediate_write_sz
# or to otherwise make better decisions, the size of the buffer
# is also represented in bins: <=4kBytes, 4-32kBytes, and > 32kBytes.
# This should help you determine if the workload contains a bunch of
# itty-bitty synchronous writes or just a few, large writes. This may
# be important because if the pool does not have a log device and the
# writes are > 32kBytes (zfs_immediate_write_sz) then they are not written
# to the ZIL, but are instead written directly to the pool. OTOH, if there
# is a separate log, then the writes are always sent to the log with the
# expectation that the log device is always faster (lower latency) than
# the pool. However, until a per-pool view is generated, the stats collected
# here are for all pools.
#
# TODO: add per-pool option which also knows about zfs_immediate_write_sz
# logic.
#
##############################
# --- Process Arguments ---
#

### default variables
opt_mega=0
opt_pool=0
opt_time=0
opt_txg=0
filter=0
pool=
lines=-1
interval=1
count=-1

### process options
while getopts hl:Mp:t name
do
case $name in
l) lines=$OPTARG ;;
        M) opt_mega=1 ;;
p) opt_pool=1; pool=$OPTARG ;;
t) opt_time=1 ;;
h|?) ME=$(basename $0)
                cat <<-END >&2
Usage: $ME [gMt][-l linecount] [-p poolname] [interval [count]]
    -M # print numbers as megabytes (base 10)
    -t # print timestamp
    -p poolname # only look at poolname
    -l linecount # print header every linecount lines (default=only once)
    interval in seconds or "txg" for transaction group commit intervals
             note: "txg" only appropriate when -p poolname is used
    count will limit the number of intervals reported

    examples:
        $ME # default output, 1 second samples
        $ME 10 # 10 second samples
        $ME 10 6 # print 6 x 10 second samples
        $ME -p rpool # show ZIL stats for rpool only

    output:
        [TIME]
        N-Bytes - data bytes written to ZIL over the interval
        N-Bytes/s - data bytes/s written to ZIL over ther interval
        N-Max-Rate - maximum data rate during any 1-second sample
        B-Bytes - buffer bytes written to ZIL over the interval
        B-Bytes/s - buffer bytes/s written to ZIL over ther interval
        B-Max-Rate - maximum buffer rate during any 1-second sample
        ops - number of synchronous iops per interval
        <=4kB - number of synchronous iops <= 4kBytes per interval
        4-32kB - number of synchronous iops 4-32kBytes per interval
        >=32kB - number of synchronous iops >= 32kBytes per interval
    note: data bytes are actual data, total bytes counts buffer size
END
exit 1
esac
done

shift $(( $OPTIND - 1 ))

### option logic
if [[ "$1" > 0 ]]; then
        interval=$1; shift
fi
if [[ "$1" > 0 ]]; then
        count=$1; shift
fi
if (( opt_pool )); then
filter=1
fi

if [[ "$interval" == "txg" ]]; then
    if [[ $opt_pool != 1 ]]; then
        echo "error: -p poolname option must be used for txg intervals"
        exit 1
    fi
    opt_txg=1
    interval=0
fi

##############################
# --- Main Program, DTrace ---

/usr/sbin/dtrace -n '
/* zil_stat.d */
#pragma D option quiet
inline int OPT_time = '$opt_time';
inline int OPT_txg = '$opt_txg';
inline int OPT_pool = '$opt_pool';
inline int OPT_mega = '$opt_mega';
inline int INTERVAL = '$interval';
inline int LINES = '$lines';
inline int COUNTER = '$count';
inline int FILTER = '$filter';
inline string POOL = "'$pool'";
dtrace:::BEGIN
{
/* starting values */
MEGA = 1000000;
counts = COUNTER;
secs = INTERVAL;
interval = INTERVAL;
interval == 0 ? interval++ : 1;
line = 0;
last_event[""] = 0;
nused=0;
nused_max_per_sec=0;
nused_per_sec=0;
size=0;
size_max_per_sec=0;
size_per_sec=0;
syncops=0;
size_4k=0;
size_4k_32k=0;
size_32k=0;
OPT_txg ? printf("waiting for txg commit...\n") : 1;
}

/*
* collect info when zil_lwb_write_start fires
*/
fbt::zil_lwb_write_start:entry
/OPT_pool == 0 || POOL == args[0]->zl_dmu_pool->dp_spa->spa_name/
{
nused += args[1]->lwb_nused;
nused_per_sec += args[1]->lwb_nused;
size += args[1]->lwb_sz;
size_per_sec += args[1]->lwb_sz;
syncops++;
args[1]->lwb_sz <= 4096 ? size_4k++ : 1;
args[1]->lwb_sz > 4096 && args[1]->lwb_sz < 32768 ? size_4k_32k++ : 1;
args[1]->lwb_sz >= 32768 ? size_32k++ : 1;
}

/*
* Timer
*/
profile:::tick-1sec
{
OPT_txg ? secs++ : secs--;
nused_per_sec > nused_max_per_sec ? nused_max_per_sec = nused_per_sec : 1;
nused_per_sec = 0;
size_per_sec > size_max_per_sec ? size_max_per_sec = size_per_sec : 1;
size_per_sec = 0;
}

/*
* Print header
*/
profile:::tick-1sec
/OPT_txg == 0 && line == 0/
{
/* print optional headers */
OPT_time ? printf("%-20s ", "TIME") : 1;

/* print header */
OPT_mega ? printf("%10s %10s %10s %10s %10s %10s",
"N-MB", "N-MB/s", "N-Max-Rate",
"B-MB", "B-MB/s", "B-Max-Rate") :
printf("%10s %10s %10s %10s %10s %10s",
"N-Bytes", "N-Bytes/s", "N-Max-Rate",
"B-Bytes", "B-Bytes/s", "B-Max-Rate");
printf(" %6s %6s %6s %6s\n",
"ops", "<=4kB", "4-32kB", ">=32kB");
line = LINES;
}

fbt::txg_quiesce:entry
/OPT_txg == 1 && POOL == args[0]->dp_spa->spa_name && line == 0/
{
OPT_time ? printf("%-20s ", "TIME") : 1;

OPT_mega ? printf("%10s %10s %10s %10s %10s %10s %10s",
"txg", "N-MB", "N-MB/s", "N-Max-Rate",
"B-MB", "B-MB/s", "B-Max-Rate") :
printf("%10s %10s %10s %10s %10s %10s %10s",
"txg", "N-Bytes", "N-Bytes/s", "N-Max-Rate",
"B-Bytes", "B-Bytes/s", "B-Max-Rate");
printf(" %6s %6s %6s %6s\n",
"ops", "<=4kB", "4-32kB", ">=32kB");
line = LINES;
}

/*
* Print Output
*/
profile:::tick-1sec
/OPT_txg == 0 && secs == 0/
{
OPT_time ? printf("%-20Y ", walltimestamp) : 1;
OPT_mega ?
printf("%10d %10d %10d %10d %10d %10d",
nused/MEGA, nused/(interval*MEGA), nused_max_per_sec/MEGA,
size/MEGA, size/(interval*MEGA), size_max_per_sec/MEGA) :
printf("%10d %10d %10d %10d %10d %10d",
nused, nused/interval, nused_max_per_sec,
size, size/interval, size_max_per_sec);
printf(" %6d %6d %6d %6d\n",
syncops, size_4k, size_4k_32k, size_32k);
nused = 0;
nused_per_sec = 0;
nused_max_per_sec = 0;
size=0;
size_max_per_sec=0;
size_per_sec=0;
syncops=0;
size_4k=0;
size_4k_32k=0;
size_32k=0;
secs = INTERVAL;
counts--;
line--;
}

fbt::txg_quiesce:entry
/OPT_txg == 1 && POOL == args[0]->dp_spa->spa_name/
{
secs <= 0 ? secs=1 : 1;
OPT_time ? printf("%-20Y ", walltimestamp) : 1;
OPT_mega ?
printf("%10d %10d %10d %10d %10d %10d %10d", args[1],
nused/MEGA, nused/(secs*MEGA), nused_max_per_sec/MEGA,
size/MEGA, size/(secs*MEGA), size_max_per_sec/MEGA) :
printf("%10d %10d %10d %10d %10d %10d %10d", args[1],
nused, nused/secs, nused_max_per_sec,
size, size/secs, size_max_per_sec);
printf(" %6d %6d %6d %6d\n",
syncops, size_4k, size_4k_32k, size_32k);
nused = 0;
nused_per_sec = 0;
nused_max_per_sec = 0;
size=0;
size_max_per_sec=0;
size_per_sec=0;
syncops=0;
size_4k=0;
size_4k_32k=0;
size_32k=0;
secs = 0;
counts--;
line--;
}

/*
* End of program
*/
profile:::tick-1sec
/OPT_txg == 0 && counts == 0/
{
exit(0);
}
fbt::txg_quiesce:entry
/OPT_txg == 1 && counts == 0/
{
exit(0);
}
'
