namespace Singularity.Nearby {

    public delegate Gee.Collection<Device> InputDevices();

    public class InputPlace : Object {
        public string output { get; set; default = ""; }
        public string side { get; set; default = "right"; }
        public int start { get; set; default = 0; }
        public int end { get; set; default = 0; }
        public int port { get; set; default = SintyScreen.PORT; }
        public string state { get; set; default = "waiting"; }
        public string address { get; set; default = ""; }
    }

    public class InputShare : Object {
        public const string[] SIDES = { "left", "right", "top", "bottom" };
        private const string FILE = "input-places.json";

        private SintyScreen screen;
        private InputDevices devices;
        private ScreenName own_name;
        private string binary;
        private string state;
        private string store;
        private Gee.HashMap<string, InputPlace> places = new Gee.HashMap<string, InputPlace>();
        private Subprocess? helper = null;
        private DataOutputStream? commands = null;
        private bool probing = false;
        private uint restart_id = 0;
        private bool stopping = false;

        public signal void changed(string id);
        public signal void pushed(string output, string side, double position, double length);
        public signal void failed(Device d, string message);
        public signal void window_dragged(string id, string state, string app_id, int pid, string output, string side, double fraction);

        public InputShare(SintyScreen screen, owned InputDevices devices, owned ScreenName own_name, string binary, string state, string config_dir) {
            this.screen = screen;
            this.devices = (owned) devices;
            this.own_name = (owned) own_name;
            this.binary = binary;
            this.state = state;
            this.store = Path.build_filename(config_dir, FILE);
            load();
            screen.input_admitted.connect(on_admitted);
        }

        public bool available {
            get { return FileUtils.test(binary, FileTest.IS_EXECUTABLE) && Environment.get_variable("WAYLAND_DISPLAY") != null; }
        }

        public bool can_place(Device d) {
            return available && screen.is_core_peer(d) && screen.address_of(d) != null;
        }

        public InputPlace? place_of(Device d) {
            return places[d.id];
        }

        private string dir_of(string id) {
            return Path.build_filename(state, id);
        }

        private bool adopted(string id) {
            return FileUtils.test(Path.build_filename(dir_of(id), "core.json"), FileTest.EXISTS);
        }

        public void place(Device d, string output, string side, int start, int end) throws NearbyError {
            if (!(side in SIDES) || output == "" || output.length > 64 || end <= start) {
                throw new NearbyError.FAILED(_("This is not a place beside a screen"));
            }
            if (!can_place(d) && !places.has_key(d.id)) {
                throw new NearbyError.FAILED(_("%s cannot use this keyboard and pointer").printf(d.name));
            }
            foreach (var entry in places.entries) {
                var other = entry.value;
                if (entry.key != d.id && other.output == output && other.side == side && other.start < end && start < other.end) {
                    other.start = other.end = 0;
                }
            }
            var p = places[d.id] ?? new InputPlace();
            bool fresh = !places.has_key(d.id);
            p.output = output;
            p.side = side;
            p.start = start;
            p.end = end;
            p.address = "";
            places[d.id] = p;
            foreach (var entry in places.entries.to_array()) {
                if (entry.value.end <= entry.value.start) forget_place(entry.key);
            }
            save();
            if (adopted(d.id)) {
                bind(d);
            } else {
                p.state = "waiting";
                ask_core.begin(d);
            }
            if (fresh) refresh();
            changed(d.id);
        }

        public void remove(string id) {
            if (!places.has_key(id)) return;
            forget_place(id);
            save();
            refresh();
        }

        public void forget_device(Device d) {
            remove(d.id);
            remove_tree(dir_of(d.id));
        }

        private void forget_place(string id) {
            places.unset(id);
            command(@"{\"cmd\":\"forget\",\"id\":$(quote(id))}");
            changed(id);
        }

        private async void ask_core(Device d) {
            try {
                DirUtils.create_with_parents(dir_of(d.id), 0700);
                yield screen.request_input(d, dir_of(d.id));
            } catch (Error e) {
                failed(d, e.message);
            }
        }

        private void on_admitted(Device d, string core_id, string core_name, string core_key, int port) {
            var p = places[d.id];
            if (p == null) return;
            adopt.begin(d, p, core_id, core_name, core_key, port);
        }

        private async void adopt(Device d, InputPlace p, string core_id, string core_name, string core_key, int port) {
            try {
                yield screen.adopt_core(dir_of(d.id), core_id, core_name, core_key);
                p.port = port;
                save();
                bind(d);
            } catch (Error e) {
                failed(d, e.message);
            }
        }

        private void bind(Device d) {
            var p = places[d.id];
            if (p == null || !adopted(d.id)) return;
            var addr = screen.address_of(d);
            if (addr == null) {
                if (p.address != "") command(@"{\"cmd\":\"forget\",\"id\":$(quote(d.id))}");
                p.address = "";
                set_state(d.id, "offline");
                return;
            }
            string core = addr.get_family() == SocketFamily.IPV6
                ? "[%s]:%d".printf(addr.to_string(), p.port)
                : "%s:%d".printf(addr.to_string(), p.port);
            if (helper == null) {
                p.address = "";
                return;
            }
            if (p.address == core && p.state != "offline" && p.state != "waiting") return;
            p.address = core;
            set_state(d.id, "connecting");
            command(@"{\"cmd\":\"place\",\"id\":$(quote(d.id)),\"core\":$(quote(core)),\"state\":$(quote(dir_of(d.id))),\"output\":$(quote(p.output)),\"side\":$(quote(p.side)),\"start\":$(p.start),\"end\":$(p.end)}");
        }

        private void set_state(string id, string value) {
            var p = places[id];
            if (p == null || p.state == value) return;
            p.state = value;
            changed(id);
        }

        public void refresh() {
            if (!available) {
                stop_helper();
                return;
            }
            bool wanted = places.size > 0;
            bool candidates = false;
            foreach (var d in devices()) {
                if (can_place(d)) {
                    wanted = true;
                    if (!places.has_key(d.id)) candidates = true;
                }
            }
            if (!wanted) {
                stop_helper();
                return;
            }
            if (helper == null) {
                start_helper();
                return;
            }
            foreach (var d in devices()) {
                if (places.has_key(d.id)) bind(d);
            }
            if (candidates != probing) {
                probing = candidates;
                command(@"{\"cmd\":\"probe\",\"on\":$(candidates ? "true" : "false")}");
            }
        }

        private void start_helper() {
            if (helper != null || restart_id != 0) return;
            try {
                helper = new Subprocess.newv({ binary, "-edges", "-name", own_name(), "-layout", SintyScreen.keyboard_layout() },
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
            } catch (Error e) {
                warning("nearby: the edge helper did not start: %s", e.message);
                helper = null;
                return;
            }
            stopping = false;
            commands = new DataOutputStream(helper.get_stdin_pipe());
            probing = false;
            foreach (var p in places.values) p.address = "";
            var proc = helper;
            read_events.begin(new DataInputStream(helper.get_stdout_pipe()), proc);
            proc.wait_async.begin(null, (o, r) => {
                try {
                    proc.wait_async.end(r);
                } catch (Error e) {
                }
                if (helper != proc) return;
                helper = null;
                commands = null;
                probing = false;
                foreach (var id in places.keys) set_state(id, "offline");
                if (stopping) return;
                restart_id = Timeout.add_seconds(3, () => {
                    restart_id = 0;
                    refresh();
                    return Source.REMOVE;
                });
            });
            refresh();
        }

        private void stop_helper() {
            if (helper == null) return;
            stopping = true;
            command("{\"cmd\":\"quit\"}");
            helper.send_signal(Posix.Signal.TERM);
            helper = null;
            commands = null;
            probing = false;
        }

        private void command(string line) {
            if (commands == null) return;
            try {
                commands.put_string(line + "\n");
                commands.flush();
            } catch (Error e) {
                debug("nearby: edge helper: %s", e.message);
            }
        }

        private async void read_events(DataInputStream stream, Subprocess proc) {
            while (true) {
                string? line;
                try {
                    line = yield stream.read_line_async(Priority.DEFAULT, null);
                } catch (Error e) {
                    return;
                }
                if (line == null) return;
                if (helper != proc) return;
                handle_event(line);
            }
        }

        private void handle_event(string line) {
            var parser = new Json.Parser();
            try {
                parser.load_from_data(line);
            } catch (Error e) {
                return;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
            var o = root.get_object();
            string event = o.get_string_member_with_default("event", "");
            string id = o.get_string_member_with_default("id", "");
            switch (event) {
                case "pushed":
                    pushed(o.get_string_member_with_default("output", ""), o.get_string_member_with_default("side", ""),
                        o.get_double_member_with_default("position", 0), o.get_double_member_with_default("length", 0));
                    break;
                case "window":
                    if (!places.has_key(id)) break;
                    window_dragged(id, o.get_string_member_with_default("state", ""), o.get_string_member_with_default("app_id", ""),
                        (int) o.get_int_member_with_default("pid", 0), o.get_string_member_with_default("output", ""),
                        o.get_string_member_with_default("side", ""), o.get_double_member_with_default("fraction", 0));
                    break;
                case "connected":
                case "left":
                    set_state(id, "connected");
                    break;
                case "entered":
                    set_state(id, "active");
                    break;
                case "disconnected":
                    set_state(id, "connecting");
                    break;
                case "error":
                    var p = places[id];
                    if (p != null) {
                        p.address = "";
                        set_state(id, "offline");
                    }
                    break;
                case "unavailable":
                    warning("nearby: this desktop does not hand its input to other devices: %s",
                        o.get_string_member_with_default("error", ""));
                    break;
            }
        }

        private void load() {
            var parser = new Json.Parser();
            try {
                parser.load_from_file(store);
            } catch (Error e) {
                return;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
            var all = root.get_object();
            foreach (string id in all.get_members()) {
                var node = all.get_member(id);
                if (node.get_node_type() != Json.NodeType.OBJECT || !Packet.valid_device_id(id)) continue;
                var o = node.get_object();
                var p = new InputPlace();
                p.output = o.get_string_member_with_default("output", "");
                p.side = o.get_string_member_with_default("side", "");
                p.start = (int) o.get_int_member_with_default("start", 0);
                p.end = (int) o.get_int_member_with_default("end", 0);
                p.port = (int) o.get_int_member_with_default("port", SintyScreen.PORT);
                p.state = "offline";
                if (p.output == "" || !(p.side in SIDES) || p.end <= p.start || p.port <= 0 || p.port > 65535) continue;
                places[id] = p;
            }
        }

        private void save() {
            var b = new Json.Builder();
            b.begin_object();
            foreach (var entry in places.entries) {
                b.set_member_name(entry.key);
                b.begin_object();
                b.set_member_name("output").add_string_value(entry.value.output);
                b.set_member_name("side").add_string_value(entry.value.side);
                b.set_member_name("start").add_int_value(entry.value.start);
                b.set_member_name("end").add_int_value(entry.value.end);
                b.set_member_name("port").add_int_value(entry.value.port);
                b.end_object();
            }
            b.end_object();
            var gen = new Json.Generator();
            gen.root = b.get_root();
            gen.pretty = true;
            try {
                DirUtils.create_with_parents(Path.get_dirname(store), 0700);
                FileUtils.set_contents_full(store, gen.to_data(null), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("nearby: %s: %s", store, e.message);
            }
        }

        private static string quote(string s) {
            var node = new Json.Node(Json.NodeType.VALUE);
            node.set_string(s);
            return Json.to_string(node, false);
        }

        private static void remove_tree(string path) {
            var dir = File.new_for_path(path);
            try {
                var e = dir.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = e.next_file()) != null) {
                    var child = dir.get_child(info.get_name());
                    if (info.get_file_type() == FileType.DIRECTORY) {
                        remove_tree(child.get_path());
                    } else {
                        child.delete();
                    }
                }
                dir.delete();
            } catch (Error e) {
                debug("nearby: %s: %s", path, e.message);
            }
        }
    }
}
