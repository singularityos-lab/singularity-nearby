namespace Singularity.Nearby {

    public delegate void ScreenSend(Device d, Packet p);
    public delegate void ScreenAsk(string summary, string body, string allow, owned NotificationAction answer);
    public delegate string ScreenName();
    public delegate InetAddress? ScreenRoute(Device d);

    public class SintyScreen : Object {
        public const string OFFER = "sinty.screen.offer";
        public const string REQUEST = "sinty.screen.request";
        public const int PORT = 7412;

        private const string CORE = "dev.sinty.Core1";
        private const string CORE_PATH = "/dev/sinty/Core1";
        private const string DBUS = "org.freedesktop.DBus";
        private const int NAME_MAX = 64;

        private ScreenSend send;
        private ScreenAsk ask;
        private ScreenName own_name;
        private ScreenRoute route;
        private string binary;
        private string state;
        private DBusConnection? system_bus = null;
        private bool core_running = false;
        private Gee.HashMap<string, string> invites = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, string> requested = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, Subprocess> viewers = new Gee.HashMap<string, Subprocess>();

        public signal void capabilities_changed();
        public signal void failed(Device d, string message);
        public signal void viewing_changed(Device d);
        public signal void input_admitted(Device d, string core_id, string core_name, string core_key, int port);

        public const string MODE_VIEW = "view";
        public const string MODE_INPUT = "input";

        public SintyScreen(owned ScreenSend send, owned ScreenAsk ask, owned ScreenName own_name, owned ScreenRoute route,
                           DBusConnection? system_bus, string binary, string state) {
            this.send = (owned) send;
            this.ask = (owned) ask;
            this.own_name = (owned) own_name;
            this.route = (owned) route;
            this.system_bus = system_bus;
            this.binary = binary;
            this.state = state;
            if (system_bus == null) return;
            try {
                system_bus.signal_subscribe(DBUS, DBUS, "NameOwnerChanged", "/org/freedesktop/DBus", CORE, DBusSignalFlags.NONE,
                    (c, s, p, i, n, args) => {
                        string name, old_owner, new_owner;
                        args.get("(sss)", out name, out old_owner, out new_owner);
                        set_core(new_owner != "");
                    });
                var reply = system_bus.call_sync(DBUS, "/org/freedesktop/DBus", DBUS, "NameHasOwner",
                    new Variant("(s)", CORE), new VariantType("(b)"), DBusCallFlags.NONE, 2000);
                bool owned;
                reply.get("(b)", out owned);
                core_running = owned;
            } catch (Error e) {
                debug("nearby: no Sinty Core here: %s", e.message);
            }
        }

        private void set_core(bool running) {
            if (running == core_running) return;
            core_running = running;
            capabilities_changed();
        }

        public bool is_core { get { return core_running; } }

        public bool can_view {
            get {
                return FileUtils.test(binary, FileTest.IS_EXECUTABLE) && Environment.get_variable("WAYLAND_DISPLAY") != null;
            }
        }

        public string[] incoming() {
            string[] out = {};
            if (is_core) out += REQUEST;
            if (can_view) out += OFFER;
            return out;
        }

        public string[] outgoing() {
            string[] out = {};
            if (is_core) out += OFFER;
            if (can_view) out += REQUEST;
            return out;
        }

        public bool can_show_on(Device d) {
            return is_core && d.paired && OFFER in d.incoming && route(d) != null;
        }

        public bool can_show_from(Device d) {
            return can_view && d.paired && REQUEST in d.incoming && route(d) != null;
        }

        public bool showing(Device d) {
            return viewers.has_key(d.id);
        }

        public void offer(Device d) throws NearbyError {
            if (!can_show_on(d)) throw new NearbyError.FAILED(_("%s cannot show this desktop").printf(d.name));
            string token = Uuid.string_random();
            invites[d.id] = token;
            send(d, new Packet(OFFER).set_string("token", token));
        }

        public async void show_from(Device d) throws Error {
            if (!can_show_from(d)) throw new NearbyError.FAILED(_("%s cannot share its desktop").printf(d.name));
            yield request(d, "");
        }

        public InetAddress? address_of(Device d) {
            return route(d);
        }

        public void stop(Device d) {
            var p = viewers[d.id];
            if (p != null) p.send_signal(Posix.Signal.TERM);
        }

        public void forget(Device d) {
            invites.unset(d.id);
            requested.unset(d.id);
            stop(d);
        }

        public bool is_core_peer(Device d) {
            return d.paired && REQUEST in d.incoming;
        }

        public async void request_input(Device d, string input_state) throws Error {
            string[] out = yield run({ binary, "-state", input_state, "-id" });
            string id = out.length > 0 ? out[0].strip() : "";
            if (id.length != 32) throw new NearbyError.FAILED(_("This device has no screen identity"));
            requested[d.id] = MODE_INPUT;
            send(d, new Packet(REQUEST).set_string("screen-id", id).set_string("screen-name", own_name())
                .set_string("token", "").set_string("mode", MODE_INPUT));
        }

        public async void adopt_core(string input_state, string core_id, string core_name, string core_key) throws Error {
            yield run({ binary, "-state", input_state, "-core-id", core_id, "-core-name", core_name, "-core-key", core_key });
        }

        public void handle(Device d, Packet p) {
            if (route(d) == null) return;
            if (p.packet_type == OFFER && (can_view || requested[d.id] == MODE_INPUT)) {
                if (p.get_string("core-key", "") != "") {
                    string? mode = requested[d.id];
                    if (mode == null) return;
                    requested.unset(d.id);
                    if (mode == MODE_INPUT) {
                        string core_id = p.get_string("core-id", "");
                        string key = p.get_string("core-key", "");
                        int port = (int) p.get_int("port", PORT);
                        if (core_id.length != 32 || key.length > 128 || port <= 0 || port > 65535) return;
                        input_admitted(d, core_id, Packet.filter_name(p.get_string("core-name", d.name)), key, port);
                        return;
                    }
                    adopt.begin(d, p);
                    return;
                }
                if (!can_view) return;
                string token = p.get_string("token", "");
                if (token == "" || token.length > 64) return;
                ask(_("Show %s Here?").printf(d.name), _("%s offers its desktop to this device.").printf(d.name), _("Show"), (action) => {
                    if (action != "accept") return;
                    request.begin(d, token, (o, r) => {
                        try {
                            request.end(r);
                        } catch (Error e) {
                            failed(d, e.message);
                        }
                    });
                });
            } else if (p.packet_type == REQUEST && is_core) {
                string id = p.get_string("screen-id", "");
                string name = Packet.filter_name(p.get_string("screen-name", d.name));
                if (id.length != 32 || name == "" || name.length > NAME_MAX) return;
                string token = p.get_string("token", "");
                string? invited = invites[d.id];
                bool input = p.get_string("mode", MODE_VIEW) == MODE_INPUT;
                if (!input && token != "" && invited == token) {
                    invites.unset(d.id);
                    admit.begin(d, id, name);
                    return;
                }
                consent.begin(d, id, name, input);
            }
        }

        private async void consent(Device d, string id, string name, bool input) {
            if (yield trusted(id)) {
                yield admit(d, id, name);
                return;
            }
            if (input) {
                ask(_("Use the Keyboard and Pointer of %s Here?").printf(d.name),
                    _("%s placed this desktop beside its screens. Its pointer and keyboard will move here when they cross the edge, and this screen stays private.").printf(d.name),
                    _("Allow"), (action) => {
                    if (action == "accept") admit.begin(d, id, name);
                });
                return;
            }
            ask(_("Let %s Use This Desktop?").printf(d.name), _("%s will see this screen and control it with its keyboard and pointer.").printf(d.name), _("Allow"), (action) => {
                if (action == "accept") admit.begin(d, id, name);
            });
        }

        private async void request(Device d, string token) throws Error {
            string[] out = yield run({ binary, "-state", state, "-id" });
            string id = out.length > 0 ? out[0].strip() : "";
            if (id.length != 32) throw new NearbyError.FAILED(_("This device has no screen identity"));
            requested[d.id] = MODE_VIEW;
            send(d, new Packet(REQUEST).set_string("screen-id", id).set_string("screen-name", own_name()).set_string("token", token));
        }

        private async bool trusted(string id) {
            try {
                var screens = yield core_property("Screens");
                var iter = screens.iterator();
                Variant? s;
                while ((s = iter.next_value()) != null) {
                    if (s.get_child_value(0).get_string() == id) return true;
                }
            } catch (Error e) {
                debug("nearby: cannot read the Core screens: %s", e.message);
            }
            return false;
        }

        private async Variant core_property(string name) throws Error {
            var reply = yield system_bus.call(CORE, CORE_PATH, "org.freedesktop.DBus.Properties", "Get",
                new Variant("(ss)", CORE, name), new VariantType("(v)"), DBusCallFlags.NONE, 5000, null);
            Variant v;
            reply.get("(v)", out v);
            return v;
        }

        private async void admit(Device d, string id, string name) {
            try {
                yield system_bus.call(CORE, CORE_PATH, CORE, "AdmitScreen", new Variant("(ss)", id, name),
                    null, DBusCallFlags.NONE, 10000, null);
                string core_id = (yield core_property("ID")).get_string();
                string core_name = (yield core_property("Name")).get_string();
                string core_key = (yield core_property("PublicKey")).get_string();
                int port = PORT;
                try {
                    port = (yield core_property("Port")).get_int32();
                } catch (Error e) {
                    debug("nearby: the Core does not say its port: %s", e.message);
                }
                send(d, new Packet(OFFER).set_string("core-id", core_id).set_string("core-name", core_name)
                    .set_string("core-key", core_key).set_int("port", port));
            } catch (Error e) {
                failed(d, e.message);
            }
        }

        private async void adopt(Device d, Packet p) {
            string core_id = p.get_string("core-id", "");
            string core_name = Packet.filter_name(p.get_string("core-name", d.name));
            string key = p.get_string("core-key", "");
            int port = (int) p.get_int("port", PORT);
            if (core_id.length != 32 || key.length > 128 || port <= 0 || port > 65535) return;
            try {
                yield run({ binary, "-state", state, "-core-id", core_id, "-core-name", core_name, "-core-key", key });
                stop(d);
                var peer = route(d);
                if (peer == null) return;
                string address = peer.get_family() == SocketFamily.IPV6
                    ? "[%s]:%d".printf(peer.to_string(), port)
                    : "%s:%d".printf(peer.to_string(), port);
                var proc = new Subprocess.newv({ binary, "-window", "-state", state, "-core", address, "-name", own_name(), "-layout", keyboard_layout() },
                    SubprocessFlags.NONE);
                viewers[d.id] = proc;
                viewing_changed(d);
                proc.wait_async.begin(null, (o, r) => {
                    try {
                        proc.wait_async.end(r);
                    } catch (Error e) {
                    }
                    if (viewers[d.id] == proc) {
                        viewers.unset(d.id);
                        viewing_changed(d);
                    }
                });
            } catch (Error e) {
                failed(d, e.message);
            }
        }

        public static string keyboard_layout() {
            var source = SettingsSchemaSource.get_default();
            var schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema == null || !schema.has_key("xkb-layout")) return "us";
            string value = new Settings("dev.sinty.desktop").get_string("xkb-layout");
            string first = value.split(",")[0].strip();
            return first != "" ? first : "us";
        }

        private async string[] run(string[] argv) throws Error {
            var proc = new Subprocess.newv(argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string stdout_text, stderr_text;
            yield proc.communicate_utf8_async(null, null, out stdout_text, out stderr_text);
            if (!proc.get_successful()) {
                throw new NearbyError.FAILED(stderr_text != null && stderr_text.strip() != "" ? stderr_text.strip() : _("The screen helper failed"));
            }
            return (stdout_text ?? "").split("\n");
        }
    }
}
