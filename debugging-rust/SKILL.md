---
name: debugging-rust
description: Use when debugging hanging, crashing, or misbehaving Rust applications by inspecting running processes
---

# Debugging Rust Applications

## Overview

Debug running Rust processes using system-level tools when the application hangs, crashes, or shows unexpected behavior. Collect backtraces, inspect state, and identify blocking operations without modifying code.

## When to Use

- Application hangs (unresponsive but not crashed)
- High CPU usage without progress
- Infinite loops or blocking operations
- Memory leaks or resource exhaustion
- Deadlocks or race conditions

## Quick Reference

| Task | Command |
|------|---------|
| Find process | `ps aux \| grep <name>` |
| Check status | `cat /proc/<pid>/status` |
| Check wait channel | `cat /proc/<pid>/wchan` |
| List threads | `ls /proc/<pid>/task/` |
| Thread wait channels | `for tid in /proc/<pid>/task/*; do echo "$tid: $(cat $tid/wchan)"; done` |
| Network connections | `cat /proc/<pid>/net/tcp` |
| Attach gdb | `gdb -batch -p <pid> -ex "thread apply all bt"` |
| Attach lldb | `lldb -p <pid> -o "thread backtrace all" -o "quit"` |
| Trace syscalls | `strace -p <pid>` |

## Core Pattern

### 1. Identify the Process

```bash
ps aux | grep -i <program_name> | grep -v grep
```

Note the PID and check basic state:
- `Sl+` = sleeping, multi-threaded, foreground
- `R+` = running, foreground
- High CPU % = spinning, not blocked

### 2. Check Process State

```bash
# Overall status
cat /proc/<pid>/status

Key fields:
- State: R (running), S (sleeping), D (uninterruptible sleep)
- Threads: number of threads
- voluntary_ctxt_switches: voluntary context switches
- nonvoluntary_ctxt_switches: forced context switches
```

### 3. Find Where It's Blocked

```bash
# Main thread wait channel
cat /proc/<pid>/wchan

# All thread wait channels
for tid in /proc/<pid>/task/*; do
  echo "$(basename $tid): $(cat $tid/wchan 2>/dev/null)"
done
```

Common wait channels:
- `futex_do_wait` = waiting on mutex/condition variable
- `do_epoll_wait` = waiting for I/O events
- `0` = running (not waiting)
- `pipe_wait` = waiting on pipe
- `sk_wait_data` = waiting on socket

### 4. Inspect Network State

```bash
cat /proc/<pid>/net/tcp
```

Look for:
- Many connections to same remote port = connection pool issue
- Connections in SYN_SENT = connection establishment blocked
- Connections with large tx_queue = not reading responses

### 5. Capture Backtrace

**With gdb:**
```bash
gdb -batch -p <pid> -ex "thread apply all bt" -ex "quit"
```

**With lldb:**
```bash
lldb -p <pid> -o "thread backtrace all" -o "quit"
```

**Permission issues:**
If you get "Operation not permitted", ptrace_scope may be set to 1:
```bash
cat /proc/sys/kernel/yama/ptrace_scope
# 0 = classic ptrace permissions
# 1 = restricted ptrace (default on many systems)
# 2 = admin-only attach
# 3 = no attach
```

### 6. Trace System Calls

```bash
# Real-time trace (stop with Ctrl+C)
strace -p <pid>

# Sample for 5 seconds
timeout 5 strace -p <pid> 2>&1
```

## Common Scenarios

### Hanging on Network I/O

Symptoms:
- `wchan` shows `sk_wait_data` or `futex_do_wait`
- Many TCP connections in `ESTABLISHED` state
- Process not consuming CPU

Debug:
```bash
# Check connections
cat /proc/<pid>/net/tcp | grep -v "00000000:0000"

# Check socket details
ls -la /proc/<pid>/fd/ | grep socket
```

### Infinite Loop

Symptoms:
- High CPU usage (95%+)
- `wchan` shows `0` (running)
- `nonvoluntary_ctxt_switches` is high

Debug:
```bash
# Sample backtraces over time
gdb -batch -p <pid> -ex "bt" -ex "quit"
sleep 1
gdb -batch -p <pid> -ex "bt" -ex "quit"

# If same function appears repeatedly = spinning
```

### Deadlock

Symptoms:
- Multiple threads in `futex_do_wait`
- No progress, low CPU
- Application completely frozen

Debug:
```bash
# Get all thread backtraces
gdb -batch -p <pid> -ex "info threads" -ex "thread apply all bt"

# Look for:
# - Threads waiting on different mutexes
# - Circular wait pattern (A holds X waits for Y, B holds Y waits for X)
```

### Async Runtime Blocked

Symptoms:
- Tokio/async-std process appears stuck
- Event loop thread in `do_epoll_wait` or `futex_do_wait`
- Async tasks not making progress

Check:
```bash
# Tokio runtime issues often show many threads in futex_do_wait
# Single event loop thread stuck = task never yields
# Check if there's a blocking operation in async code
```

## Implementation

### Complete Debugging Script

```bash
#!/bin/bash
PID=$1

if [ -z "$PID" ]; then
  echo "Usage: $0 <pid>"
  exit 1
fi

echo "=== Process Status ==="
cat /proc/$PID/status | grep -E "(Name|State|Threads|voluntary|nonvoluntary)"

echo -e "\n=== Wait Channel ==="
cat /proc/$PID/wchan

echo -e "\n=== Thread Wait Channels ==="
for tid in /proc/$PID/task/*; do
  if [ -d "$tid" ]; then
    wchan=$(cat "$tid/wchan" 2>/dev/null || echo "unknown")
    echo "$(basename $tid): $wchan"
  fi
done

echo -e "\n=== Active Connections ==="
cat /proc/$PID/net/tcp | wc -l
echo "Total TCP sockets (includes listening)"

echo -e "\n=== Open File Descriptors ==="
ls /proc/$PID/fd/ | wc -l
echo "Total FDs"

if command -v gdb &> /dev/null; then
  echo -e "\n=== Backtrace (first 5 frames) ==="
  gdb -batch -p $PID -ex "thread apply all bt 5" -ex "quit" 2>&1 | head -50
else
  echo -e "\n=== GDB not available ==="
fi
```

## Common Mistakes

**Assuming high CPU = working**
- High CPU with no progress usually means infinite loop
- Check `wchan` - if `0`, it's spinning

**Not checking all threads**
- Main thread may be idle while worker threads are stuck
- Always check `/proc/<pid>/task/` for all threads

**Ignoring wait channels**
- `futex_do_wait` = blocked on synchronization
- `do_epoll_wait` = waiting for I/O
- `0` = actually running

**Missing ptrace restrictions**
- Many Linux systems restrict ptrace with Yama LSM
- Check `/proc/sys/kernel/yama/ptrace_scope`
- May need root or scope change to attach debugger

## Example: Tokio Async Hang

```bash
# Find process
ps aux | grep clanker
# 1679514 94.9 ... Sl+ target/debug/clanker

# Check state
cat /proc/1679514/wchan
# futex_do_wait

# Check threads
for tid in /proc/1679514/task/*; do echo "$tid: $(cat $tid/wchan)"; done
# 1679514: futex_do_wait (main thread blocked)
# 1679516: do_epoll_wait (event loop waiting)
# 1679517-1679536: futex_do_wait (workers blocked)

# Check connections
cat /proc/1679514/net/tcp | grep 01BB | wc -l
# 37 connections to port 443 (HTTPS)

# Root cause: Async task collecting events into Vec
# and only processing after await completes
# Fix: Process events immediately in callback
```

## Real-World Impact

This technique identified a bug in clanker where the async runtime was collecting events into a Vec instead of processing them immediately, causing the UI to freeze when waiting for tool approval. The fix was processing events in the callback rather than after the await completes.