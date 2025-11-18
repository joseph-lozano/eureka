# Eureka.MachineManager Testing Checklist

## 📋 Context for New LLM Sessions

This document provides comprehensive testing guidance for the Eureka.MachineManager GenServer. The MachineManager handles Fly.io machine lifecycle for the Eureka platform, which provides AI coding assistant sessions.

### 🎯 What We're Testing

**Eureka.MachineManager** is a GenServer that:
- Manages Fly.io virtual machines for individual user repositories
- Handles machine lifecycle (create, start, suspend, auto-suspend)
- Provides retry logic with exponential backoff for network errors
- Ensures machines are available for opencode sessions
- Auto-suspends machines after 60 seconds of inactivity to save resources

### 🏗️ Architecture Overview

```
User Request → MachineManager → Fly API → Machine
     ↓                    ↓              ↓
  Timer Reset          Network Error    Auto-Suspend (60s)
     ↓                    ↓              ↓
  Machine Running ← Start Machine ← Suspend Machine
```

### 🔧 Key Components Being Tested

1. **Machine Lifecycle Management**
   - Creating new machines via Fly.io API
   - Starting suspended machines
   - Suspending active machines
   - Auto-suspending after inactivity timeout

2. **Network Error Recovery**
   - Detecting `{:network_error, %Req.TransportError{reason: :nxdomain}}`
   - Automatic machine restart and request retry
   - Exponential backoff: 1s → 2s → 4s → 8s

3. **Timer Management**
   - 60-second inactivity timer
   - Timer reset on each successful request
   - Prevention of premature suspensions

4. **Data Persistence**
   - Machine ID storage in JSON files
   - Path structure: `<data_dir>/<user_id>/<username>/<repo_name>.json`
   - Graceful handling of missing/corrupted data

5. **Request Serialization**
   - All operations serialized through GenServer
   - Global naming: `{:global, {user_id, username, repo_name}}`
   - Prevention of concurrent machine operations

### 🧪 Why This Testing Matters

The MachineManager is critical infrastructure for:
- **Resource Management**: Ensuring machines are only running when needed
- **Cost Control**: Auto-suspending idle machines to reduce Fly.io costs
- **User Experience**: Fast recovery from network issues without manual intervention
- **Reliability**: Proper error handling and retry logic for production stability

### 📊 Expected Behavior Patterns

- **Cold Start**: First request creates machine (~10-30s)
- **Warm Start**: Subsequent requests are instant (<1s)
- **Suspend/Resume**: Manual suspend → instant resume on next request
- **Auto-Suspend**: 60s after last request → resume on next request
- **Error Recovery**: Network error → auto-start → retry with backoff

This testing ensures the MachineManager can reliably manage the compute resources that power the Eureka coding assistant platform.

## 🚀 Setup

- [x] Start iex: `iex -S mix`
- [x] Start GenServer with test data
  ```elixir
  {:ok, pid} = Eureka.MachineManager.start_link(%{
    user_id: "test_user_123", 
    username: "testuser", 
    repo_name: "test-repo"
  })
  ```

## 🧪 Core Functionality Tests

### Machine ID Retrieval
- [x] Test `Eureka.MachineManager.get_machine_id(pid)` returns `{:ok, machine_id}` after machine creation
- [x] Test with no machine returns `{:error, :no_machine}`

### List Sessions (First Time)
- [x] Test `Eureka.MachineManager.list_sessions(pid)` creates machine and returns sessions
- [x] Verify logs show machine creation
- [x] Verify request completes quickly (<5s)

### Manual Suspend
- [x] Test `Eureka.MachineManager.suspend_machine(pid)` suspends immediately
- [x] Verify logs show suspension message
- [x] Verify return value is `{:ok, machine_id}`

### Request After Suspend (Auto-Restart)
- [x] Test `Eureka.MachineManager.list_sessions(pid)` after suspension
- [x] Verify logs show: network error → start machine → retry sequence
- [x] Verify request completes within 8-10 seconds
- [x] Verify machine is responsive after restart

## ⏱️ Auto-Suspend Timer Tests

### 60-Second Auto-Suspend
- [x] Make request to start timer: `Eureka.MachineManager.list_sessions(pid)`
- [x] Wait 65 seconds: `:timer.sleep(65_000)`
- [x] Verify logs show auto-suspend message
- [x] Test `Eureka.MachineManager.list_sessions(pid)` restarts machine again
- [x] Verify auto-suspend only happens after 60s of inactivity

### Timer Reset on Activity
- [ ] Start timer: `Eureka.MachineManager.list_sessions(pid)`
- [ ] Wait 30 seconds: `:timer.sleep(30_000)`
- [ ] Make another request to reset timer: `Eureka.MachineManager.list_sessions(pid)`
- [ ] Wait 40 more seconds (total 70s from start, but only 40s since last request)
- [ ] Verify machine is NOT suspended (timer was reset)
- [ ] Verify subsequent request works without restart

## 🔁 Error Scenario Tests

### Network Error Recovery
- [ ] Suspend machine: `Eureka.MachineManager.suspend_machine(pid)`
- [ ] Immediately make request: `Eureka.MachineManager.list_sessions(pid)`
- [ ] Verify logs show network error detection
- [ ] Verify logs show machine startup
- [ ] Verify logs show retry sequence with backoff
- [ ] Verify request ultimately succeeds

### Timeout Handling
- [ ] Test request timing: `{time, result} = :timer.tc(fn -> Eureka.MachineManager.list_sessions(pid) end)`
- [ ] Verify fast requests complete quickly (<1s)
- [ ] Verify requests requiring machine startup take longer (~8-10s)
- [ ] Verify all requests complete within 20s timeout

### Multiple Requests
- [ ] Test concurrent requests (should be serialized)
- [ ] Verify timer resets on each request
- [ ] Verify no race conditions or crashes

## 🗂️ Persistence Tests

### Machine Data Persistence
- [ ] Stop GenServer: `GenServer.stop(pid)`
- [ ] Restart with same parameters
- [ ] Verify `Eureka.MachineManager.get_machine_id(new_pid)` returns same machine_id
- [ ] Verify no duplicate machine creation

### File Structure Verification
- [ ] Check machine data file exists: `ls -la ./test_user_123/testuser/`
- [ ] Verify `test-repo.json` file contains valid JSON
- [ ] Verify file contains `{"machine_id": "..."}`
- [ ] Verify file permissions are correct

## 🚨 Edge Case Tests

### No Machine Scenario
- [ ] Delete test data: `File.rm_rf("./test_user_123")`
- [ ] Start fresh GenServer
- [ ] Verify `get_machine_id` returns `{:error, :no_machine}` initially
- [ ] Verify first request creates machine successfully

### Invalid Machine Data
- [ ] Create corrupted JSON: `echo '{"invalid": "data"}' > ./test_user_123/testuser/test-repo.json`
- [ ] Restart GenServer
- [ ] Verify graceful handling of invalid format
- [ ] Verify new machine creation succeeds
- [ ] Verify logs show appropriate warnings

### Missing Configuration
- [ ] Test with missing Fly API configuration
- [ ] Verify graceful error handling
- [ ] Verify appropriate error messages

## 📊 Log Verification

Throughout testing, verify these log patterns appear correctly:

### Success Logs
- [ ] `"Created new machine [machine_id] for [username]/[repo_name]"`
- [ ] `"Started existing machine [machine_id] for [username]/[repo_name]"`
- [ ] `"Suspended machine [machine_id] for [username]/[repo_name]"`
- [ ] `"Auto-suspending machine [machine_id] due to inactivity"`
- [ ] `"Started machine [machine_id], retrying [action]"`

### Error Logs
- [ ] `"Failed to start machine [machine_id]: [reason]"`
- [ ] `"Failed to suspend machine [machine_id]: [reason]"`
- [ ] `"Failed to create machine for [username]/[repo_name]: [reason]"`
- [ ] `"Failed to load machine data for [username]/[repo_name]: [reason]"`

### Warning Logs
- [ ] `"Invalid machine data format in [file]: [data]"`
- [ ] `"Failed to start machine [machine_id], creating new machine: [reason]"`

## 🧹 Cleanup

- [ ] Stop GenServer: `GenServer.stop(pid)`
- [ ] Clean test data: `File.rm_rf("./test_user_123")`
- [ ] Verify no processes left hanging
- [ ] Verify no timer references leaked

## 🔍 Debug Commands (if needed)

### State Inspection
- [ ] `:sys.get_state(pid)` - Check current GenServer state
- [ ] `:sys.trace(pid, true)` - Enable message tracing
- [ ] `Process.info(pid)` - Check process information
- [ ] `:erlang.read_timer(:erlang.send_after(3))` - Check active timers

### Network Debug
- [ ] Test machine connectivity manually
- [ ] Verify Fly API configuration
- [ ] Check DNS resolution for machine hostname

## ✅ Success Criteria

All tests should pass if:

1. **Basic Operations Work**
   - [ ] Machine creation, listing, suspension all functional
   - [ ] Return values are correct tuples with expected data

2. **Timer Logic Works**
   - [ ] Auto-suspend after exactly 60 seconds of inactivity
   - [ ] Timer resets properly on each request
   - [ ] No premature suspensions

3. **Error Recovery Works**
   - [ ] Network errors detected and handled correctly
   - [ ] Machine restarts automatically when needed
   - [ ] Retry logic uses proper backoff timing

4. **Persistence Works**
   - [ ] Machine data saved and loaded correctly
   - [ ] No data loss between restarts
   - [ ] File structure created properly

5. **No Crashes or Leaks**
   - [ ] GenServer never crashes during normal operations
   - [ ] No memory leaks from timers or tasks
   - [ ] All processes cleaned up properly

6. **Performance Acceptable**
   - [ ] Fast requests complete in <1 second
   - [ ] Slow requests (with restart) complete in <10 seconds
   - [ ] No GenServer timeout deaths

---

## 📝 Test Results

After running tests, fill in results:

### Core Functionality
- Machine ID Retrieval: ✅ / ❌
- List Sessions (first): ✅ / ❌
- Manual Suspend: ✅ / ❌
- Request After Suspend: ✅ / ❌

### Auto-Suspend Timer
- 60-Second Auto-Suspend: ✅ / ❌
- Timer Reset on Activity: ✅ / ❌

### Error Scenarios
- Network Error Recovery: ✅ / ❌
- Timeout Handling: ✅ / ❌
- Multiple Requests: ✅ / ❌

### Persistence
- Machine Data Persistence: ✅ / ❌
- File Structure: ✅ / ❌

### Edge Cases
- No Machine Scenario: ✅ / ❌
- Invalid Machine Data: ✅ / ❌
- Missing Configuration: ✅ / ❌

### Overall Stability
- No Crashes: ✅ / ❌
- No Memory Leaks: ✅ / ❌
- Performance Acceptable: ✅ / ❌

### Issues Found
- [ ] List any issues discovered during testing
- [ ] Note any edge cases that failed
- [ ] Record any performance problems
- [ ] Document any unexpected behavior