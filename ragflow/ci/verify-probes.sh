#!/bin/sh
# Probe verification WITHOUT self-matching contamination.
#
# Earlier attempts embedded the pattern in the test script itself, so PID 1
# (the `sh -c <whole script>` process) contained the pattern and every pgrep
# matched it. The script is written to a FILE here, so the pattern never
# appears in any process's command line except the intended target.

echo "=== negative control: target process NOT running ==="
pgrep -f "[r]ag/svr/task_executor.py" > /dev/null
echo "bracket  exit=$?  (expect 1 = correctly unhealthy)"

pgrep -f "rag/svr/task_executor.py" > /dev/null
echo "plain    exit=$?  (expect 1 here too, since nothing embeds the pattern)"

echo
echo "=== positive control: start a matching process ==="
mkdir -p /tmp/rag/svr
cp /bin/sleep /tmp/rag/svr/task_executor.py
/tmp/rag/svr/task_executor.py 60 &
sleep 1

pgrep -f "[r]ag/svr/task_executor.py" > /dev/null
echo "bracket  exit=$?  (expect 0 = correctly healthy)"

echo
echo "=== the real risk: probe pattern inside the probe's own cmdline ==="
# This is what a Kubernetes exec probe literally does.
sh -c 'pgrep -f "rag/svr/task_executor.py" > /dev/null'
echo "unbracketed via sh -c exit=$?  (0 would mean SELF-MATCH bug)"

sh -c 'pgrep -f "[r]ag/svr/task_executor.py" > /dev/null'
echo "bracketed   via sh -c exit=$?  (0 is legitimate: target is running)"

echo
echo "=== kill target, re-test the sh -c form ==="
pkill -f "[t]ask_executor.py" 2>/dev/null
sleep 1
sh -c 'pgrep -f "rag/svr/task_executor.py" > /dev/null'
echo "unbracketed, no target: exit=$?  (MUST be 1; 0 = self-match bug)"

sh -c 'pgrep -f "[r]ag/svr/task_executor.py" > /dev/null'
echo "bracketed,   no target: exit=$?  (MUST be 1)"
