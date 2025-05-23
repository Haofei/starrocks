#!/usr/bin/env bash
# Copyright 2021-present StarRocks, Inc. All rights reserved.
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

BIN_NAME=starrocks_be
MACHINE_TYPE=$(uname -m)

# ================== parse opts =======================
curdir=`dirname "$0"`
curdir=`cd "$curdir"; pwd`

OPTS=$(getopt \
    -n $0 \
    -o '' \
    -l 'daemon' \
    -l 'cn' \
    -l 'be' \
    -l 'logconsole' \
    -l 'meta_tool' \
    -l numa: \
    -l 'check_mem_leak' \
    -l 'jemalloc_debug' \
-- "$@")

eval set -- "$OPTS"

RUN_DAEMON=0
RUN_CN=0
RUN_BE=0
RUN_NUMA="-1"
RUN_LOG_CONSOLE=0
RUN_META_TOOL=0
RUN_CHECK_MEM_LEAK=0
RUN_JEMALLOC_DEBUG=0

while true; do
    case "$1" in
        --daemon) RUN_DAEMON=1 ; shift ;;
        --cn) RUN_CN=1; RUN_BE=0; shift ;;
        --be) RUN_BE=1; RUN_CN=0; shift ;;
        --logconsole) RUN_LOG_CONSOLE=1 ; shift ;;
        --numa) RUN_NUMA=$2; shift 2 ;;
        --meta_tool) RUN_META_TOOL=1 ; shift ;;
        --check_mem_leak) RUN_CHECK_MEM_LEAK=1 ; shift ;;
        --jemalloc_debug) RUN_JEMALLOC_DEBUG=1 ; shift ;;
        --) shift ;  break ;;
        *) echo "Internal error" ; exit 1 ;;
    esac
done

# ================== conf section =======================
export STARROCKS_HOME=`cd "$curdir/.."; pwd`
source $STARROCKS_HOME/bin/common.sh

export_shared_envvars

check_and_update_max_processes

if [ ${RUN_BE} -eq 1 ] ; then
    export_env_from_conf $STARROCKS_HOME/conf/be.conf
fi
if [ ${RUN_CN} -eq 1 ]; then
    export_env_from_conf $STARROCKS_HOME/conf/cn.conf
fi

if [ $? -ne 0 ]; then
    exit 1
fi

# enable jemalloc
JEMALLOC_LIB=$STARROCKS_HOME/lib/libjemalloc.so
ln -s -f $STARROCKS_HOME/lib/libjemalloc.so.2 $JEMALLOC_LIB
export LD_LIBRARY_PATH=$STARROCKS_HOME/lib:$LD_LIBRARY_PATH

# Set JEMALLOC_CONF environment variable if not already set
if [[ -z "$JEMALLOC_CONF" ]]; then
    # JEMALLOC enable DEBUG 
    if [ ${RUN_JEMALLOC_DEBUG} -eq 1 ] ; then
        ln -s -f $STARROCKS_HOME/lib/libjemalloc-dbg.so.2 $JEMALLOC_LIB
        export JEMALLOC_CONF="junk:true,tcache:false,prof:true"
    elif [ ${RUN_CHECK_MEM_LEAK} -eq 1 ] ; then
        export JEMALLOC_CONF="percpu_arena:percpu,oversize_threshold:0,muzzy_decay_ms:5000,dirty_decay_ms:5000,metadata_thp:auto,background_thread:true,prof:true,prof_active:true,prof_leak:true,lg_prof_sample:0,prof_final:true"
    else
        export JEMALLOC_CONF="percpu_arena:percpu,oversize_threshold:0,muzzy_decay_ms:5000,dirty_decay_ms:5000,metadata_thp:auto,background_thread:true,prof:true,prof_active:false"
    fi
fi

# enable coredump when BE build with ASAN
export ASAN_OPTIONS="abort_on_error=1:disable_coredump=0:unmap_shadow_on_exit=1:detect_stack_use_after_return=1"
export LSAN_OPTIONS=suppressions=${STARROCKS_HOME}/conf/asan_suppressions.conf


# ================== jvm section =======================
if [ -e $STARROCKS_HOME/conf/hadoop_env.sh ]; then
    source $STARROCKS_HOME/conf/hadoop_env.sh
fi

# NOTE: JAVA_HOME must be configed if using hdfs scan, like hive external table
jvm_arch="amd64"
if [[ "${MACHINE_TYPE}" == "aarch64" ]]; then
    jvm_arch="aarch64"
fi

if [ "$JAVA_HOME" = "" ]; then
    echo "[WARNING] JAVA_HOME env not set. Functions or features that requires jni will not work at all."
    export LD_LIBRARY_PATH=$STARROCKS_HOME/lib:$LD_LIBRARY_PATH
else
    export LD_LIBRARY_PATH=$JAVA_HOME/lib/server:$JAVA_HOME/lib:$LD_LIBRARY_PATH
    java_version=$(jdk_version)
    if [[ $java_version -lt 17 ]]; then
        echo "[WARNING] jdk versions lower than 17 are not supported"
    fi
fi


# check NUMA setting
NUMA_CMD=""
if [[ "${RUN_NUMA}" -ne "-1" ]]; then
    set -e
    NUMA_CMD="numactl --cpubind ${RUN_NUMA} --membind ${RUN_NUMA}"
    ${NUMA_CMD} echo "Running on NUMA ${RUN_NUMA}"
    set +e
fi

final_java_opt=${JAVA_OPTS}
# Compatible with scenarios upgraded from jdk9~jdk16
if [ ! -z "${JAVA_OPTS_FOR_JDK_9_AND_LATER}" ] ; then
    echo "Warning: Configuration parameter JAVA_OPTS_FOR_JDK_9_AND_LATER is not supported, JAVA_OPTS is the only place to set jvm parameters"
    final_java_opt=${JAVA_OPTS_FOR_JDK_9_AND_LATER}
fi

# Appending the option to avoid "process heaper" stack overflow exceptions.
final_java_opt="$final_java_opt -Djdk.lang.processReaperUseDefaultStackSize=true"
export LIBHDFS_OPTS=$final_java_opt
# Prevent JVM from handling any internally or externally generated signals.
# Otherwise, JVM will overwrite the signal handlers for SIGINT and SIGTERM.
export LIBHDFS_OPTS="$LIBHDFS_OPTS -Xrs"

# HADOOP_CLASSPATH defined in $STARROCKS_HOME/conf/hadoop_env.sh
# put $STARROCKS_HOME/conf ahead of $HADOOP_CLASSPATH so that custom config can replace the config in $HADOOP_CLASSPATH
export CLASSPATH=${STARROCKS_HOME}/lib/jni-packages/starrocks-hadoop-ext.jar:$STARROCKS_HOME/conf:$STARROCKS_HOME/lib/jni-packages/*:$HADOOP_CLASSPATH:$CLASSPATH


# ================= native section =====================
export LD_LIBRARY_PATH=$STARROCKS_HOME/lib/hadoop/native:$LD_LIBRARY_PATH


# ====== handle meta_tool sub command before any modification change
if [ ${RUN_META_TOOL} -eq 1 ] ; then
    ${STARROCKS_HOME}/lib/$BIN_NAME meta_tool "$@"
    exit $?
fi

# ================== kill/start =======================
if [ ! -d $LOG_DIR ]; then
    mkdir -p $LOG_DIR
fi

if [ ! -d $UDF_RUNTIME_DIR ]; then
    mkdir -p ${UDF_RUNTIME_DIR}
fi

if [ ${RUN_BE} -eq 1 ]; then
    pidfile=$PID_DIR/be.pid
fi
if [ ${RUN_CN} -eq 1 ]; then
    pidfile=$PID_DIR/cn.pid
fi

if [ -f $pidfile ]; then
    # check if the binary name can be grepped from the process cmdline.
    # still it has chances to be false positive, but the possibility is greatly reduced.
    oldpid=$(cat $pidfile)
    pscmd=$(ps -q $oldpid -o cmd=)
    if echo "$pscmd" | grep -q -w "$BIN_NAME" &>/dev/null ; then
        echo "Backend running as process $oldpid. Stop it first."
        exit 1
    else
        rm $pidfile
    fi
fi

chmod 755 ${STARROCKS_HOME}/lib/$BIN_NAME

if [ $(ulimit -n) != "unlimited" ] && [ $(ulimit -n) -lt 60000 ]; then
    ulimit -n 65535
fi

START_BE_CMD="${NUMA_CMD} ${STARROCKS_HOME}/lib/$BIN_NAME"
LOG_FILE=$LOG_DIR/be.out
if [ ${RUN_CN} -eq 1 ]; then
    START_BE_CMD="${START_BE_CMD} --cn"
    LOG_FILE=${LOG_DIR}/cn.out
fi

# enable DD profile
if [ "${ENABLE_DATADOG_PROFILE}" == "true" ] && [ -f "${STARROCKS_HOME}/datadog/ddprof" ]; then
    START_BE_CMD="${STARROCKS_HOME}/datadog/ddprof -l debug ${START_BE_CMD}"
fi

if [ ${RUN_LOG_CONSOLE} -eq 1 ] ; then
    # force glog output to console (stderr)
    export GLOG_logtostderr=1
else
    # redirect stdout/stderr to ${LOG_FILE}
    exec >> ${LOG_FILE} 2>&1
fi

echo "start time: $(date), server uptime: $(uptime)"
echo "Run with JEMALLOC_CONF: '$JEMALLOC_CONF'"

if [ ${RUN_DAEMON} -eq 1 ]; then
    nohup ${START_BE_CMD} "$@" </dev/null &
else
    exec ${START_BE_CMD} "$@" </dev/null
fi
