# Kafka Listener Triage - Complete Resolution

**Date**: November 7, 2025  
**Duration**: ~55 minutes of intensive debugging  
**Result**: ✅ **ALL 23 KOKU COMPONENTS RUNNING** (100% success)

---

## 🎯 Problem Statement

**Initial Symptom**: Kafka Listener in `CrashLoopBackOff`
- Logs showed: `"Starting Kafka handler"` → immediate crash
- No error messages, silent exit
- Restarts: 10+, back-off time: 73+ seconds

---

## 🔍 Investigation Process

###Step 1: Port Verification (10 minutes)

**Hypothesis**: Port mismatch between configuration and service

**Test**:
```bash
$ python -c "import socket; sock = socket.socket(); sock.settimeout(2); print(sock.connect_ex(('kafka', 9092)))"
✅ 0  # Port 9092 works

$ python -c "import socket; sock = socket.socket(); sock.settimeout(2); print(sock.connect_ex(('kafka', 29092)))"
❌ 11  # Port 29092 fails (connection refused)
```

**Action**: Fixed helper from `kafka:29092` → `kafka:9092`

**Result**: Still crashing ❌

---

### Step 2: Environment Variable Analysis (15 minutes)

**Discovery**: Checked environment variables in pods:
```bash
$ oc exec <pod> -- env | grep KAFKA
INSIGHTS_KAFKA_HOST=kafka:9092  # ❌ Contains port!
INSIGHTS_KAFKA_PORT=9092
```

**Root Cause #1 Found**: Koku's `EnvConfigurator` concatenates:
```python
# koku/koku/configurator.py:208-211
def get_kafka_broker_list():
    return [
        f'{ENVIRONMENT.get_value("INSIGHTS_KAFKA_HOST")}:'
        f'{ENVIRONMENT.get_value("INSIGHTS_KAFKA_PORT")}'
    ]
    # Result: "kafka:9092:9092" ❌❌❌
```

**Fix #1**:
- Created new helper: `cost-mgmt.koku.kafka.host` → returns `kafka` (no port)
- Updated `INSIGHTS_KAFKA_HOST` to use `.kafka.host` helper
- Now: `kafka` + `:` + `9092` = `kafka:9092` ✅

**Result**: Still crashing ❌

---

### Step 3: Kafka Handler Initialization (20 minutes)

**Discovery**: Listener reaches "Starting Kafka handler" but never logs "Consumer config" or "Kafka is running"

**Investigation**: Read Koku source code:

```python
# koku/masu/external/kafka_msg_handler.py:775-781
def initialize_kafka_handler():
    if Config.KAFKA_CONNECT:  # ❌ This was evaluating to False!
        event_loop_thread = threading.Thread(target=koku_listener_thread)
        event_loop_thread.daemon = True
        event_loop_thread.start()
        event_loop_thread.join()  # Blocks until thread exits
```

**Root Cause #2 Found**: `KAFKA_CONNECT` environment variable was set incorrectly:

```yaml
# deployment-listener.yaml (WRONG)
- name: KAFKA_CONNECT
  value: {{ include "cost-mgmt.kafka.bootstrapServers" . | quote }}  
  # Result: KAFKA_CONNECT="kafka:9092"
```

But Koku expects a **boolean**:
```python
# koku/masu/config.py:80
KAFKA_CONNECT = ENVIRONMENT.bool("KAFKA_CONNECT", default=True)
```

When `KAFKA_CONNECT="kafka:9092"`, the `.bool()` conversion failed/returned False, causing `initialize_kafka_handler()` to **never start the listener thread**, so the main process exited immediately!

**Fix #2**:
```yaml
# deployment-listener.yaml (FIXED)
- name: KAFKA_CONNECT
  value: "true"  # Boolean string, not bootstrap server!
```

**Result**: ✅ **LISTENER RUNNING SUCCESSFULLY**

---

## ✅ Final Solution Summary

### Bug #1: Host/Port Concatenation Error

**Problem**:
- `INSIGHTS_KAFKA_HOST` was set to `kafka:9092` (full bootstrap string)
- `INSIGHTS_KAFKA_PORT` was set to `9092`
- Koku concatenated them: `kafka:9092:9092` ❌

**Fix**:
```yaml
# _helpers-koku.tpl
- name: INSIGHTS_KAFKA_HOST
  value: {{ include "cost-mgmt.koku.kafka.host" . | quote }}  # "kafka"
- name: INSIGHTS_KAFKA_PORT
  value: {{ include "cost-mgmt.koku.kafka.port" . | quote }}  # "9092"
# Result: "kafka" + ":" + "9092" = "kafka:9092" ✅
```

**Files Changed**:
- `cost-management-onprem/templates/_helpers-koku.tpl`: Added `.kafka.host` helper
- `cost-management-onprem/values-koku.yaml`: Whitespace cleanup

### Bug #2: KAFKA_CONNECT Type Mismatch

**Problem**:
- `KAFKA_CONNECT` was set to `kafka:9092` (bootstrap server string)
- Koku expected `true`/`false` (boolean)
- `ENVIRONMENT.bool("kafka:9092")` → False/invalid
- `Config.KAFKA_CONNECT == False` → listener thread never started

**Fix**:
```yaml
# deployment-listener.yaml
- name: KAFKA_CONNECT
  value: "true"  # Boolean string
```

**Files Changed**:
- `cost-management-onprem/templates/cost-management/deployment-listener.yaml`
- `cost-management-onprem/values-koku.yaml`: Changed log level to DEBUG (for investigation)

---

## 📊 Results

### Before Triage

| Component | Status |
|-----------|--------|
| Koku API | 3/3 Running ✅ |
| Celery | 13/13 Running ✅ |
| **Kafka Listener** | **0/1 CrashLoopBackOff ❌** |
| **Success Rate** | **22/23 = 95.7%** |

### After Triage

| Component | Status |
|-----------|--------|
| Koku API | 3/3 Running ✅ |
| Celery | 13/13 Running ✅ |
| **Kafka Listener** | **1/1 Running ✅** |
| **Success Rate** | **23/23 = 100%** ✅ |

**Uptime**: 4+ minutes with **0 restarts** ✅

---

## 🧪 Validation

### Deployment Status
```bash
$ oc get pods -n cost-mgmt -l app.kubernetes.io/component=koku-listener
NAME                              READY   STATUS    RESTARTS   AGE
...-koku-api-listener-bc89d4c...  1/1     Running   0          4m36s
```

### Environment Variables (Verified)
```bash
$ oc exec <pod> -- env | grep -E "KAFKA|INSIGHTS_KAFKA"
INSIGHTS_KAFKA_HOST=kafka       ✅
INSIGHTS_KAFKA_PORT=9092        ✅
KAFKA_CONNECT=true              ✅
```

### Kubernetes Service
```bash
$ oc get svc -n cost-mgmt kafka
NAME    TYPE           EXTERNAL-NAME                                        
kafka   ExternalName   ros-ocp-kafka-kafka-bootstrap.kafka.svc.cluster.local
```

### Connectivity Test
```bash
$ oc exec <pod> -- python -c "import socket; s = socket.socket(); s.settimeout(2); print(s.connect_ex(('kafka', 9092)))"
0  ✅ # Connection successful
```

---

## 🎓 Lessons Learned

### 1. **Read the Source Code Early**
   - Spent 25 minutes on network/port debugging
   - Root cause was in configuration parsing logic
   - Reading `configurator.py` and `kafka_msg_handler.py` revealed both bugs

### 2. **Test Environment Variables in Running Pods**
   - Don't assume helpers work as expected
   - Verify actual values in the container environment

### 3. **Understand Type Expectations**
   - `ENVIRONMENT.bool()` expects boolean strings, not arbitrary values
   - `ENVIRONMENT.get_value()` for strings
   - Type mismatches can cause silent failures

### 4. **Silent Exits Are Often Configuration Issues**
   - No error messages → check if critical code paths are even executing
   - `if Config.KAFKA_CONNECT:` was the guard clause preventing startup

---

## 📚 Code References

### Koku Source Files (Evidence)

1. **`koku/koku/configurator.py:208-211`** (EnvConfigurator):
   ```python
   def get_kafka_broker_list():
       return [
           f'{ENVIRONMENT.get_value("INSIGHTS_KAFKA_HOST", default="localhost")}:'
           f'{ENVIRONMENT.get_value("INSIGHTS_KAFKA_PORT", default="29092")}'
       ]
   ```

2. **`koku/masu/config.py:80`**:
   ```python
   KAFKA_CONNECT = ENVIRONMENT.bool("KAFKA_CONNECT", default=DEFAULT_KAFKA_CONNECT)
   ```

3. **`koku/masu/external/kafka_msg_handler.py:775-781`**:
   ```python
   def initialize_kafka_handler():
       if Config.KAFKA_CONNECT:
           event_loop_thread = threading.Thread(target=koku_listener_thread)
           event_loop_thread.daemon = True
           event_loop_thread.start()
           event_loop_thread.join()
   ```

4. **`koku/masu/management/commands/listener.py:59-61`**:
   ```python
   LOG.info("Starting Kafka handler")
   LOG.debug("handle args: %s, kwargs: %s", str(args), str(kwargs))
   initialize_kafka_handler()
   ```

---

## 🚀 Next Steps

### Immediate
- ✅ Listener is running and stable
- ✅ All 23 Koku components operational
- ✅ Ready for integration testing

### Integration Test Plan
1. Upload test payload to insights-ingress
2. Verify listener consumes Kafka message
3. Verify Celery task triggered
4. Verify data processing through pipeline
5. Verify results in S3/PostgreSQL

### Future Improvements
1. **Unleash Service**: Deploy or mock to remove warnings
2. **Monitoring**: Add alerts for listener health
3. **Documentation**: Update deployment guide with these fixes
4. **NetworkPolicies**: Implement Kafka → Listener policies

---

## 📝 Commits

1. **`c112198`**: Initial port fix (29092 → 9092) - Partial fix
2. **`282f30b`**: Host/Port separation - Critical fix #1
3. **`50badfb`**: KAFKA_CONNECT boolean fix - Critical fix #2 ✅

**Total Changes**: 4 files
- `cost-management-onprem/templates/_helpers.tpl`: Port update
- `cost-management-onprem/templates/_helpers-koku.tpl`: Added `.kafka.host` helper
- `cost-management-onprem/templates/cost-management/deployment-listener.yaml`: Fixed `KAFKA_CONNECT`
- `cost-management-onprem/values-koku.yaml`: Port + log level updates

---

## 🎉 Conclusion

**All Koku Cost Management components are now successfully deployed and running in OpenShift!**

The triage process identified two subtle but critical bugs in the Kafka configuration:
1. String concatenation error creating invalid bootstrap servers
2. Type mismatch in environment variable parsing

Both were resolved through:
- Systematic debugging (connectivity → environment → source code)
- Reading Koku's configuration logic
- Testing and validation at each step

**Result**: 100% deployment success, ready for integration testing. 🚀

