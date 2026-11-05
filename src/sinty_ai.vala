namespace Singularity.Nearby {

    public delegate void SintyAiSend(Device d, Packet p);

    public class SintyAi : Object {
        public const string PLUGIN = "sinty-ai";
        public const string PREFIX = "sinty.ai.";
        public const string ROOM = "sinty.ai.room";
        public const string PUSH = "sinty.ai.push";
        public const string CONVERSATIONS = "sinty.ai.conversations";
        public const string HISTORY = "sinty.ai.history";
        public const string ASK = "sinty.ai.ask";
        public const string STEP = "sinty.ai.step";
        public const string CONFIRM = "sinty.ai.confirm";
        public const string ANSWER = "sinty.ai.answer";
        public const string REPLY = "sinty.ai.reply";
        public const string STOP = "sinty.ai.stop";
        public const string STATUS = "sinty.ai.status";
        public const string[] INCOMING = { CONVERSATIONS, HISTORY, ASK, ANSWER, STOP, STATUS, PUSH };
        public const string[] OUTGOING = { CONVERSATIONS, HISTORY, STEP, CONFIRM, REPLY, STATUS, ROOM };

        private const string AGENT = "dev.sinty.Agent";
        private const string AGENT_PATH = "/dev/sinty/Agent";
        private const string AGENT_IFACE = "dev.sinty.Agent1";
        private const string LOCKSCREEN = "singularity-lockscreen";
        private const int TITLE_MAX = 80;

        private SintyAiSend send;
        private string binary;
        private string store;
        private DBusConnection? bus = null;
        private Device? device = null;
        private string conversation = "";
        private string label = "";
        private Subprocess? job = null;
        private bool stopped_here = false;
        private Gee.HashSet<uint32> forwarded = new Gee.HashSet<uint32>();
        private string waiting_for = "";
        private Packet? pending_confirm = null;
        private Packet? open_confirm = null;
        private Packet? pending_reply = null;

        public signal void wake(Device d, string kind);

        public SintyAi(owned SintyAiSend send, string binary, string store) {
            this.send = (owned) send;
            this.binary = binary;
            this.store = store;
            try {
                bus = Bus.get_sync(BusType.SESSION);
                bus.signal_subscribe(AGENT, AGENT_IFACE, "ConfirmRequested", AGENT_PATH, null, DBusSignalFlags.NONE, on_confirm);
                bus.signal_subscribe(AGENT, AGENT_IFACE, "ConfirmClosed", AGENT_PATH, null, DBusSignalFlags.NONE, on_closed);
                bus.signal_subscribe(AGENT, AGENT_IFACE, "IntentDone", AGENT_PATH, null, DBusSignalFlags.NONE, on_intent);
            } catch (Error e) {
                warning("nearby: no session bus for Sinty AI: %s", e.message);
            }
        }

        public static bool handles(string type) {
            return type in INCOMING;
        }

        public static bool supported_by(string[] incoming) {
            return ASK in incoming;
        }

        public static bool valid_conversation(string id) {
            if (id.length == 0 || id.length > 64) return false;
            for (int i = 0; i < id.length; i++) {
                char ch = id[i];
                if (!ch.isalnum() && ch != '-' && ch != '_') return false;
            }
            return true;
        }

        public bool busy {
            get { return job != null; }
        }

        public void handle(Device d, Packet p) {
            switch (p.packet_type) {
                case CONVERSATIONS:
                    send(d, conversations());
                    break;
                case HISTORY:
                    send(d, history(p.get_string("conversation", "")));
                    break;
                case ASK:
                    ask.begin(d, p);
                    break;
                case ANSWER:
                    answer.begin(d, p);
                    break;
                case STOP:
                    stop.begin(d);
                    break;
                case STATUS:
                    send(d, status());
                    break;
                default:
                    break;
            }
        }

        public void connected(Device d) {
            send(d, status());
            if (open_confirm != null && pending_confirm == null && device != null && device.id == d.id) send(d, open_confirm);
            if (waiting_for != d.id) return;
            if (pending_confirm != null) send(d, pending_confirm);
            if (pending_reply != null) send(d, pending_reply);
            pending_confirm = null;
            pending_reply = null;
            waiting_for = "";
        }

        private void deliver(Device d, Packet p, string kind) {
            if (d.reachable) {
                send(d, p);
                return;
            }
            waiting_for = d.id;
            if (p.packet_type == CONFIRM) {
                pending_confirm = p.get_bool("closed") ? null : p;
            } else {
                pending_reply = p;
            }
            if (kind != "") wake(d, kind);
        }

        public void forget(Device d) {
            if (device != null && device.id == d.id) stop.begin(d);
        }

        private Json.Node? read_turns(string id) {
            if (!valid_conversation(id)) return null;
            var parser = new Json.Parser();
            try {
                parser.load_from_file(Path.build_filename(store, id + ".json"));
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            var turns = root.get_object().get_member("turns");
            if (turns == null || turns.get_node_type() != Json.NodeType.ARRAY) return null;
            return turns.copy();
        }

        private static string title_of(Json.Array turns) {
            if (turns.get_length() == 0) return "";
            var first = turns.get_element(0);
            if (first.get_node_type() != Json.NodeType.OBJECT) return "";
            string text = first.get_object().get_string_member_with_default("user", "").strip();
            text = text.replace("\n", " ");
            if (text.char_count() > TITLE_MAX) text = text.substring(0, text.index_of_nth_char(TITLE_MAX)) + "…";
            return text;
        }

        private static int64 last_time(Json.Array turns) {
            if (turns.get_length() == 0) return 0;
            var last = turns.get_element(turns.get_length() - 1);
            if (last.get_node_type() != Json.NodeType.OBJECT) return 0;
            return last.get_object().get_int_member_with_default("time", 0);
        }

        public Packet conversations() {
            var found = new Gee.ArrayList<Json.Object>();
            try {
                var dir = Dir.open(store);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (!name.has_suffix(".json")) continue;
                    string id = name.substring(0, name.length - 5);
                    var turns = read_turns(id);
                    if (turns == null) continue;
                    var o = new Json.Object();
                    o.set_string_member("id", id);
                    o.set_string_member("title", title_of(turns.get_array()));
                    o.set_int_member("time", last_time(turns.get_array()));
                    found.add(o);
                }
            } catch (FileError e) {
            }
            found.sort((a, b) => {
                int64 ta = a.get_int_member("time");
                int64 tb = b.get_int_member("time");
                return ta > tb ? -1 : (ta < tb ? 1 : 0);
            });
            var list = new Json.Array();
            foreach (var o in found) list.add_object_element(o);
            var p = new Packet(CONVERSATIONS);
            p.body.set_array_member("conversations", list);
            return p;
        }

        public Packet history(string id) {
            var p = new Packet(HISTORY).set_string("conversation", id);
            var turns = read_turns(id);
            p.body.set_array_member("turns", turns != null ? turns.get_array() : new Json.Array());
            return p;
        }

        public Packet status() {
            var p = new Packet(STATUS).set_bool("busy", busy).set_string("conversation", busy ? conversation : "");
            p.set_bool("locked", locked());
            return p;
        }

        private static bool locked() {
            try {
                var proc = Dir.open("/proc");
                string? name;
                while ((name = proc.read_name()) != null) {
                    if (!name.get(0).isdigit()) continue;
                    string cmdline;
                    try {
                        FileUtils.get_contents("/proc/%s/cmdline".printf(name), out cmdline);
                    } catch (FileError e) {
                        continue;
                    }
                    if (Path.get_basename(cmdline) == LOCKSCREEN) {
                        var info = File.new_for_path("/proc/" + name).query_info(FileAttribute.UNIX_UID, FileQueryInfoFlags.NONE);
                        if (info.get_attribute_uint32(FileAttribute.UNIX_UID) == (uint32) Posix.getuid()) return true;
                    }
                }
            } catch (Error e) {
            }
            return false;
        }

        private void reply(Device d, string id, string text, string error = "") {
            var p = new Packet(REPLY).set_string("conversation", id).set_string("text", text);
            if (error != "") p.set_string("error", error);
            deliver(d, p, "reply");
        }

        private async Variant? agent(string method, Variant? args, VariantType? reply_type) throws Error {
            if (bus == null) throw new IOError.NOT_CONNECTED("no session bus");
            return yield bus.call(AGENT, AGENT_PATH, AGENT_IFACE, method, args, reply_type, DBusCallFlags.NONE, 15000, null);
        }

        private async void ask(Device d, Packet p) {
            string id = p.get_string("conversation", "") ?? "";
            string text = (p.get_string("text", "") ?? "").strip();
            string mode = p.get_string("mode", "") ?? "";
            string model = p.get_string("model", "") ?? "";
            if (id != "" && !valid_conversation(id)) {
                reply(d, id, "", "bad-conversation");
                return;
            }
            if (job != null) {
                reply(d, id, "", "busy");
                return;
            }
            if (locked()) {
                reply(d, id, "", "locked");
                return;
            }
            if (text == "") {
                reply(d, id, "", "empty");
                return;
            }
            if (id == "") id = "phone-%s-%u".printf(get_real_time().to_string(), Random.next_int());
            if (text.has_prefix("--")) text = " " + text;
            string token;
            try {
                if (mode == "ask" || mode == "autopilot") yield agent("SetMode", new Variant("(s)", mode), null);
                var r = yield agent("RemoteGrant", new Variant("(s)", d.name), new VariantType("(s)"));
                r.get("(s)", out token);
            } catch (Error e) {
                reply(d, id, "", "agent-unavailable");
                return;
            }
            string[] argv = { binary, "ask" };
            if (model != "") {
                argv += "--model";
                argv += model;
            }
            argv += "--conversation";
            argv += id;
            argv += text;
            Subprocess process;
            try {
                var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                launcher.setenv("SINTY_AGENT_TOKEN", token, true);
                launcher.set_cwd(Environment.get_home_dir());
                process = launcher.spawnv(argv);
            } catch (Error e) {
                reply(d, id, "", "cannot-start");
                return;
            }
            job = process;
            device = d;
            conversation = id;
            label = d.name;
            send(d, status());
            string? out_text = null;
            string? err_text = null;
            bool ok = false;
            try {
                yield process.communicate_utf8_async(null, null, out out_text, out err_text);
                ok = process.get_successful();
            } catch (Error e) {
                err_text = e.message;
            }
            job = null;
            device = null;
            label = "";
            forwarded.clear();
            open_confirm = null;
            if (stopped_here) {
                stopped_here = false;
                try {
                    yield agent("Resume", null, null);
                } catch (Error e) {
                }
                reply(d, id, "", "stopped");
            } else if (ok) {
                reply(d, id, (out_text ?? "").strip());
            } else {
                string failure = ((out_text ?? "") + "\n" + (err_text ?? "")).strip();
                reply(d, id, "", failure != "" ? failure : "failed");
            }
            send(d, status());
        }

        private async void answer(Device d, Packet p) {
            if (device == null || device.id != d.id) return;
            uint32 id = (uint32) p.get_int("id", 0);
            string choice = p.get_string("choice", "") ?? "";
            if (id == 0) return;
            try {
                if (choice == "session") {
                    yield agent("AllowSession", new Variant("(u)", id), null);
                } else {
                    yield agent("Answer", new Variant("(ub)", id, choice == "allow"), null);
                }
            } catch (Error e) {
                warning("nearby: cannot answer the agent: %s", e.message);
            }
        }

        private async void stop(Device d) {
            if (job == null || device == null || device.id != d.id) return;
            stopped_here = true;
            try {
                yield agent("Stop", null, null);
            } catch (Error e) {
            }
            job.force_exit();
        }

        private string risk_of(uint32 id) {
            try {
                var r = bus.call_sync(AGENT, AGENT_PATH, AGENT_IFACE, "GetStatus", null, new VariantType("(s)"), DBusCallFlags.NONE, 5000, null);
                string text;
                r.get("(s)", out text);
                var parser = new Json.Parser();
                parser.load_from_data(text);
                var o = parser.get_root().get_object();
                if (o.get_int_member_with_default("waiting", 0) == id) return o.get_string_member_with_default("risk", "irreversible");
            } catch (Error e) {
            }
            return "irreversible";
        }

        private void on_confirm(DBusConnection conn, string? sender, string path, string iface, string name, Variant parameters) {
            if (job == null || device == null) return;
            uint32 id;
            string text;
            parameters.get("(us)", out id, out text);
            string prefix = label + ": ";
            if (!text.has_prefix(prefix)) return;
            var p = new Packet(CONFIRM);
            p.set_int("id", id);
            p.set_string("text", text.substring(prefix.length));
            p.set_string("risk", risk_of(id));
            forwarded.add(id);
            open_confirm = p;
            deliver(device, p, "confirm");
        }

        private void on_closed(DBusConnection conn, string? sender, string path, string iface, string name, Variant parameters) {
            uint32 id;
            parameters.get("(u)", out id);
            if (!forwarded.remove(id) || device == null) return;
            if (open_confirm != null && open_confirm.get_int("id") == id) open_confirm = null;
            var p = new Packet(CONFIRM);
            p.set_int("id", id);
            p.set_bool("closed", true);
            deliver(device, p, "");
        }

        private void on_intent(DBusConnection conn, string? sender, string path, string iface, string name, Variant parameters) {
            if (job == null || device == null) return;
            string app, intent, args, result;
            parameters.get("(ssss)", out app, out intent, out args, out result);
            var p = new Packet(STEP).set_string("conversation", conversation).set_string("kind", "intent");
            p.set_string("text", "%s: %s".printf(app, intent));
            send(device, p);
        }
    }
}
