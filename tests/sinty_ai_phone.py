import json, os, socket, ssl, subprocess, sys, tempfile, threading, time, uuid
from gi.repository import Gio, GLib

if len(sys.argv) > 1 and sys.argv[1] == "fake-sinty":
    args = sys.argv[2:]
    conversation = args[args.index("--conversation") + 1]
    text = args[-1].strip()
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
    fh = s.makefile("rw")
    fh.write("token " + os.environ.get("SINTY_AGENT_TOKEN", "") + "\n"); fh.flush()
    def tool(name, **k):
        fh.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": k}}) + "\n"); fh.flush()
        r = json.loads(fh.readline())["result"]
        return r["isError"], r["content"][0]["text"]
    if text == "wait":
        time.sleep(60)
    e1, _ = tool("app_invoke", app="dev.sinty.fake", intent="note", args={"text": text})
    e2, t2 = tool("app_invoke", app="dev.sinty.fake", intent="send", args={})
    path = os.path.join(os.environ["XDG_STATE_HOME"], "sinty-agent", "conversations")
    os.makedirs(path, exist_ok=True)
    answer = "note %s, send %s" % ("failed" if e1 else "done", "failed: " + t2 if e2 else "done")
    with open(os.path.join(path, conversation + ".json"), "w") as f:
        json.dump({"turns": [{"time": int(time.time()), "user": text, "answer": answer}]}, f)
    print(answer)
    sys.exit(0)

if len(sys.argv) > 1 and sys.argv[1] == "fake-app":
    XML = """<node><interface name="dev.sinty.AppAgent1">
<method name="ListIntents"><arg type="s" direction="out"/></method>
<method name="Context"><arg type="s" direction="out"/></method>
<method name="Invoke"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
</interface></node>"""
    INTENTS = [{"name": "note", "description": "n", "risk": "undoable", "schema": {}}, {"name": "send", "description": "s", "risk": "irreversible", "schema": {}}]
    def method(conn, sender, path, iface, name, params, inv):
        if name == "ListIntents":
            inv.return_value(GLib.Variant("(s)", (json.dumps(INTENTS),)))
        elif name == "Context":
            inv.return_value(GLib.Variant("(s)", ("{}",)))
        else:
            inv.return_value(GLib.Variant("(s)", ('{"ok":true}',)))
    loop = GLib.MainLoop()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    bus.register_object("/dev/sinty/fake", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], method, None, None)
    Gio.bus_own_name_on_connection(bus, "dev.sinty.fake", 0, None, None)
    GLib.timeout_add_seconds(150, loop.quit)
    loop.run()
    sys.exit(0)

NEARBY, AGENT = sys.argv[1], sys.argv[2]
work = tempfile.mkdtemp()
PORT = 17180
with open(work + "/nearby.conf", "w") as f:
    f.write("[Nearby]\nEnabled=true\nDiscovery=\nUdpPort=%d\nTcpPorts=%d;%d;\nTransferPorts=%d;%d;\n" % (PORT, PORT, PORT + 4, PORT + 5, PORT + 9))
env = dict(os.environ, HOME=work, XDG_CONFIG_HOME=work + "/config", XDG_DATA_HOME=work + "/data", XDG_CACHE_HOME=work + "/cache",
           XDG_STATE_HOME=work + "/state", SINGULARITY_NEARBY_CONF=work + "/nearby.conf")
with open(work + "/sinty", "w") as f:
    f.write("#!/bin/sh\nexec %s %s fake-sinty \"$@\"\n" % (sys.executable, os.path.abspath(sys.argv[0])))
os.chmod(work + "/sinty", 0o755)
env["SINTY_BINARY"] = work + "/sinty"
procs = [subprocess.Popen([AGENT + "/sinty-agentd"], env=env, stderr=subprocess.DEVNULL),
         subprocess.Popen([sys.executable, sys.argv[0], "fake-app"], env=env)]
time.sleep(1)
procs.append(subprocess.Popen([NEARBY], env=env, stderr=open(work + "/nearby.log", "w")))
time.sleep(2)

fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:200] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)

device_id = uuid.uuid4().hex
subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "30",
                "-subj", "/CN=" + device_id, "-keyout", work + "/phone.key", "-out", work + "/phone.crt"], check=True, capture_output=True)
OUT = ["sinty.ai.conversations", "sinty.ai.history", "sinty.ai.ask", "sinty.ai.answer", "sinty.ai.stop", "sinty.ai.status"]
IN = ["sinty.ai.conversations", "sinty.ai.history", "sinty.ai.step", "sinty.ai.confirm", "sinty.ai.reply", "sinty.ai.status"]
def identity():
    return {"id": int(time.time() * 1000), "type": "kdeconnect.identity", "body": {"deviceId": device_id, "deviceName": "Pixel di Prova",
            "deviceType": "phone", "protocolVersion": 8, "incomingCapabilities": IN, "outgoingCapabilities": OUT, "tcpPort": PORT + 20}}
raw = socket.create_connection(("127.0.0.1", PORT), timeout=10)
raw.sendall((json.dumps(identity()) + "\n").encode())
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(work + "/phone.crt", work + "/phone.key")
ctx.verify_mode = ssl.CERT_NONE
tls = ctx.wrap_socket(raw, server_side=True)
reader = tls.makefile("rb")
desktop = json.loads(reader.readline())
check("the desktop identifies itself inside TLS", desktop["type"] == "kdeconnect.identity", desktop)
check("the desktop declares the Sinty AI packets", "sinty.ai.ask" in desktop["body"].get("incomingCapabilities", []), desktop["body"])
lock = threading.Lock()
def send(kind, **body):
    with lock:
        tls.sendall((json.dumps({"id": int(time.time() * 1000), "type": kind, "body": body}) + "\n").encode())
send("kdeconnect.identity", **identity()["body"])

packets = []
def pump():
    while True:
        try:
            line = reader.readline()
        except (OSError, ValueError):
            return
        if not line:
            return
        p = json.loads(line)
        packets.append(p)
        if p["type"] == "sinty.ai.confirm" and auto_answer and not p["body"].get("closed"):
            send("sinty.ai.answer", id=p["body"]["id"], choice=auto_answer)
auto_answer = "allow"
threading.Thread(target=pump, daemon=True).start()
def wait(kind, since, cond=lambda b: True, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        for p in packets[since:]:
            if p["type"] == kind and cond(p["body"]):
                return p["body"]
        time.sleep(0.05)
    return None

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def nearby(method, args=None):
    try:
        bus.call_sync("dev.sinty.Nearby", "/dev/sinty/Nearby", "dev.sinty.Nearby1", method, args, None, Gio.DBusCallFlags.NONE, 10000)
        return None
    except GLib.Error as e:
        return e.message
send("kdeconnect.pair", pair=True, timestamp=int(time.time()))
time.sleep(1)
err = nearby("AcceptPair", GLib.Variant("(s)", (device_id,)))
check("the desktop accepts the pairing", err is None and wait("kdeconnect.pair", 0, lambda b: b.get("pair")) is not None, err)

n = len(packets)
send("sinty.ai.conversations")
check("a paired phone without the plugin gets no answer", wait("sinty.ai.conversations", n, timeout=2) is None)

n = len(packets)
err = nearby("SetPluginEnabled", GLib.Variant("(ssb)", (device_id, "sinty-ai", True)))
st = wait("sinty.ai.status", n)
check("turning the plugin on sends the status", err is None and st is not None and st["busy"] is False and st["locked"] is False, (err, st))

n = len(packets)
send("sinty.ai.conversations")
c = wait("sinty.ai.conversations", n)
check("the phone lists no conversations at first", c is not None and c["conversations"] == [], c)

n = len(packets)
send("sinty.ai.ask", conversation="", text="salva la nota", mode="ask")
busy = wait("sinty.ai.status", n, lambda b: b["busy"])
check("the desktop says it is working", busy is not None and busy["conversation"].startswith("phone-"), busy)
conv = busy["conversation"] if busy else ""
send("sinty.ai.ask", conversation=conv, text="ancora", mode="ask")
check("a second ask while working is refused as busy", wait("sinty.ai.reply", n, lambda b: b.get("error") == "busy") is not None)
step = wait("sinty.ai.step", n)
check("the phone sees the intent step", step is not None and step["kind"] == "intent" and "dev.sinty.fake: note" in step["text"] and step["conversation"] == conv, step)
confirms = []
end = time.time() + 15
while time.time() < end and len(confirms) < 1:
    confirms = [p["body"] for p in packets[n:] if p["type"] == "sinty.ai.confirm" and not p["body"].get("closed")]
    time.sleep(0.05)
check("the phone gets the confirmation", len(confirms) == 1, confirms)
check("the confirmation names the action, not the phone", confirms and confirms[0]["text"].startswith("app_invoke"), confirms)
check("the confirmation carries its risk", [c["risk"] for c in confirms] == ["irreversible"], confirms)
r = wait("sinty.ai.reply", n, lambda b: b.get("conversation") == conv and "error" not in b, timeout=20)
check("the phone learns the question is closed", wait("sinty.ai.confirm", n, lambda b: b.get("closed") and confirms and b["id"] == confirms[0]["id"]) is not None)
check("the answer reaches the phone", r is not None and r["text"] == "note done, send done", r)
check("the desktop says it is idle again", wait("sinty.ai.status", n, lambda b: not b["busy"]) is not None)

n = len(packets)
send("sinty.ai.conversations")
c = wait("sinty.ai.conversations", n)
check("the new conversation is listed", c is not None and [x["id"] for x in c["conversations"]] == [conv] and c["conversations"][0]["title"] == "salva la nota", c)
n = len(packets)
send("sinty.ai.history", conversation=conv)
h = wait("sinty.ai.history", n)
check("the history comes back", h is not None and h["turns"][0]["answer"] == "note done, send done", h)
n = len(packets)
send("sinty.ai.history", conversation="../../etc/passwd")
h = wait("sinty.ai.history", n)
check("a bad conversation id reads nothing", h is not None and h["turns"] == [], h)

auto_answer = "deny"
n = len(packets)
send("sinty.ai.ask", conversation=conv, text="manda", mode="ask")
r = wait("sinty.ai.reply", n, lambda b: "error" not in b, timeout=25)
check("a denial from the phone stops the action", r is not None and "send failed" in r["text"], r)

n = len(packets)
send("sinty.ai.ask", conversation=conv, text="wait", mode="ask")
wait("sinty.ai.status", n, lambda b: b["busy"])
send("sinty.ai.stop", conversation=conv)
r = wait("sinty.ai.reply", n, lambda b: b.get("error") == "stopped")
check("Stop from the phone ends the work", r is not None, [p for p in packets[n:]])
st = json.loads(bus.call_sync("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", "GetStatus", None, GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 5000).unpack()[0])
check("the agent runs again after a phone Stop", st["stopped"] is False, st)

nearby("SetPluginEnabled", GLib.Variant("(ssb)", (device_id, "sinty-ai", False)))
n = len(packets)
send("sinty.ai.ask", conversation=conv, text="salva", mode="ask")
check("with the plugin off the phone is ignored", wait("sinty.ai.reply", n, timeout=3) is None)

for p in procs:
    p.terminate()
if fails:
    print(open(work + "/nearby.log").read()[-3000:])
print("phone=%d" % len(fails))
sys.exit(1 if fails else 0)
